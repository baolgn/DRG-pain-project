/* check compiled firmware on real local-memory RTL with an independent effect ledger. */
#include "Vdrg5_soc.h"
#include "verilated.h"
#include "arch_trace_fields.h"
#include <array>
#include <cstdint>
#include <deque>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>

/* one physical descriptor survives stalls until its tagged response is consumed. */
struct Owner {
    bool valid=false, accepted=false, write=false, response_seen=false;
    uint32_t address=0, data=0, tag=0, reply=0;
    unsigned size=0, lanes=0, parcels=0, status=0, acceptance=0, response=0;
    uint64_t offered=0, accepted_at=0;
};

/* errors identify the actual violated invariant rather than merely reporting a timeout. */
static void check(bool condition,const std::string &reason) {
    if (!condition) throw std::runtime_error(reason);
}

/* the checker reads the same initialization files without controlling target responses. */
class Machine {
    Vdrg5_soc dut;
    std::array<uint32_t,2048> rom{};
    std::array<uint32_t,16384> iram{};
    std::array<uint32_t,8192> dram{};
    std::array<bool,8192> written{};
    std::array<uint32_t,32> registers{};
    std::array<bool,32> defined{};
    Owner instruction,data;
    std::ofstream trace;
    std::deque<std::string> history;
    uint32_t random_state,result=0,status=0,output=0,pending=0,enabled=0;
    uint64_t clocks=0,events=0,retired=0,traps=0,irqs=0,order=0,last_uid=0;
    uint64_t instruction_accepts=0,data_accepts=0,timer=0,compare=~uint64_t(0);
    uint64_t outputs=0,status_writes=0,idle_clocks=0,unknown_sources=0;
    unsigned acceptance_bins=0,response_bins=0,hold_bins=0;
    uint32_t minimum_sp=0x20008000;
    uint32_t startup_pc=0,data_start=0,data_end=0,data_load=0,bss_start=0,bss_end=0,boot_marker=0;
    bool software=false,finished=false,completion=false,external_due=false,external_sent=false,stack_ready=false,startup_checked=false,stress;
    std::string console;

    /* deterministic schedules are independent of initial register and RAM values. */
    uint32_t random_word() {
        random_state^=random_state<<13;random_state^=random_state>>17;random_state^=random_state<<5;
        return random_state;
    }

    /* full word images avoid hidden zero initialization of ordinary data RAM. */
    template<size_t N> void load(const std::string &path,std::array<uint32_t,N> &memory) {
        std::ifstream stream(path);check(bool(stream),"missing initialization image");
        std::string token;size_t cursor=0,count=0;
        /* readmemh address directives are word indices, not byte addresses. */
        while (stream>>token) {
            /* explicit directives can skip padding but cannot expand a memory. */
            if (token[0]=='@') cursor=std::stoul(token.substr(1),nullptr,16);
            /* every initialized word must be inside its physical array. */
            else {
                check(cursor<N,"initialization exceeds physical memory");
                memory[cursor++]=uint32_t(std::stoul(token,nullptr,16));++count;
            }
        }
        check(count==N,"initialization image must cover every word");
    }

    /* physical addresses select only the three declared arrays. */
    uint32_t &word(uint32_t address) {
        if (address<0x2000) return rom[address/4];
        if (address>=0x10000 && address<0x20000) return iram[(address-0x10000)/4];
        if (address>=0x20000000 && address<0x20008000) return dram[(address-0x20000000)/4];
        throw std::runtime_error("shadow memory address");
    }

    /* generated offsets bind observation decoding to the production trace declaration. */
    uint64_t field(unsigned lsb,unsigned width) {
        uint64_t value=0;
        /* wide fields may cross the simulator's packed-word boundaries. */
        for (unsigned bit=0;bit<width;++bit) value|=uint64_t((dut.trace_o[(lsb+bit)/32]>>((lsb+bit)%32))&1)<<bit;
        return value;
    }

    /* ordered records expose missing tails and permit independent replay. */
    void record(const std::string &payload) {
        trace<<"{\"sequence\":"<<++events<<",\"cycle\":"<<clocks<<","<<payload<<"}\n";
    }

    /* first valid reserves a descriptor even while the target refuses acceptance. */
    void offer(Owner &owner,bool valid,uint32_t address,uint32_t value,uint32_t tag,
               bool write,unsigned size,unsigned lanes,unsigned parcels,unsigned accept_delay,unsigned response_delay,const char *bus) {
        check(!owner.valid || owner.accepted || valid,"withdrawn request");
        check(!owner.valid || !owner.accepted || !valid,"overlapping request");
        /* capture the first visible request independently of target ownership state. */
        if (valid && !owner.valid) {
            owner=Owner{};owner.valid=true;owner.address=address;owner.data=value;owner.tag=tag;
            owner.write=write;owner.size=size;owner.lanes=lanes;owner.parcels=parcels;
            owner.acceptance=accept_delay;owner.response=response_delay;owner.offered=clocks;
            acceptance_bins|=1u<<accept_delay;response_bins|=1u<<response_delay;
            record("\"event\":\"offer\",\"bus\":\""+std::string(bus)+"\",\"address\":"+std::to_string(address)+
                ",\"data\":"+std::to_string(value)+",\"tag\":"+std::to_string(tag)+",\"write\":"+std::to_string(write)+
                ",\"size\":"+std::to_string(size)+",\"lanes\":"+std::to_string(lanes));
        }
        check(!valid || (owner.address==address && owner.data==value && owner.tag==tag && owner.write==write &&
            owner.size==size && owner.lanes==lanes && owner.parcels==parcels),"unstable request");
        check(!owner.valid || clocks-owner.offered<=64,"local transaction exceeded service bound");
    }

    /* the timer model captures pre-edge state and applies writes after its ordinary tick. */
    uint32_t timer_read(uint32_t address) {
        /* each implemented register has a separate observable value. */
        switch (address) {
            case 0x40001000:return uint32_t(timer);
            case 0x40001004:return uint32_t(timer>>32);
            case 0x40001008:return uint32_t(compare);
            case 0x4000100c:return uint32_t(compare>>32);
            case 0x40001010:return software;
            case 0x40001014:return pending;
            case 0x40001018:return enabled;
            case 0x4000101c:case 0x40001024:return 0;
            default:throw std::runtime_error("unsupported timer model read");
        }
    }

    /* effects are predicted from accepted bus descriptors, never from retirement. */
    void accept(Owner &owner,bool fetch) {
        check(owner.valid && !owner.accepted,"duplicate or unowned acceptance");
        check(clocks-owner.offered>=owner.acceptance,"request accepted before configured delay");
        check(clocks-owner.offered<=owner.acceptance+(fetch?1u:0u),"request admission exceeded bound");
        owner.accepted=true;owner.accepted_at=clocks;owner.reply=0;owner.status=0;
        /* the CPU must expose only naturally aligned, correctly strobed data requests. */
        if (!fetch) {
            check(owner.size<=2 && (owner.address&((1u<<owner.size)-1))==0,"malformed data request");
            unsigned lanes=owner.write?((1u<<(1u<<owner.size))-1)<<(owner.address&3):0;
            check(owner.lanes==lanes,"incorrect byte enables");
        }
        bool memory=owner.address<0x2000 || (owner.address>=0x10000 && owner.address<0x20000) ||
            (owner.address>=0x20000000 && owner.address<0x20008000);
        /* local reads and enabled-byte writes use the independent memory shadow. */
        if (memory) {
            check(!fetch || owner.address<0x20000,"instruction access outside executable memory");
            /* data memory effects preserve all disabled byte lanes. */
            if (owner.write) {
                check(owner.address>=0x10000,"write reached read-only ROM");
                uint32_t mask=0;
                /* construct enabled byte masks without using any RTL load result. */
                for (unsigned lane=0;lane<4;++lane) if (owner.lanes&(1u<<lane)) mask|=0xffu<<(lane*8);
                word(owner.address)=(word(owner.address)&~mask)|(owner.data&mask);
                if (owner.address>=0x20000000) written[(owner.address-0x20000000)/4]=true;
            } else owner.reply=word(owner.address);
        /* simple output registers retain their previous accepted values on reads. */
        } else if (owner.address==0x40000000) {
            /* the first result store is still required to complete and retire. */
            if (owner.write) {
                check(!completion,"duplicate result effect");completion=true;result=owner.data;status=owner.data;++status_writes;
            } else owner.reply=status;
        /* a character write is an externally visible effect exactly once. */
        } else if (owner.address==0x40000004) {
            /* retain console text for comparison across timing and occupancy modes. */
            if (owner.write) {output=owner.data&255;console+=char(output);++outputs;if (output=='R') external_due=true;}
            else owner.reply=output;
        /* an injected event changes the same retained controller as a physical event input. */
        } else if (owner.address==0x40000008) {
            if (owner.write && (owner.data&1)) pending|=2;
        /* timer reads capture pre-edge values; timer writes are applied separately below. */
        } else if (owner.address>=0x40001000 && owner.address<=0x40001024 && (owner.address&3)==0) {
            bool readonly=owner.address==0x4000101c || owner.address==0x40001024;
            bool writeonly=owner.address==0x40001020;
            /* the acquisition queue is empty in this standalone platform test. */
            if ((readonly && owner.write) || (writeonly && (!owner.write || (owner.data&1)))) owner.status=1;
            else if (!owner.write) owner.reply=timer_read(owner.address);
        } else owner.status=1;
        /* rejected operations have a definite no-effect response. */
        if (owner.status) owner.reply=0;
        /* instruction parcels retain canonical zeros outside their requested mask. */
        if (fetch) {
            owner.reply&=(owner.parcels&1?0xffffu:0)|(owner.parcels&2?0xffff0000u:0);++instruction_accepts;
        /* the data contract requires zero outside requested lanes, even for readable RAM. */
        } else {
            unsigned width=1u<<owner.size;
            uint32_t mask=width==4?0xffffffffu:((1u<<(width*8))-1)<<(8*(owner.address&3));
            owner.reply=owner.write || owner.status?0:owner.reply&mask;++data_accepts;
        }
        record("\"event\":\"accept\",\"bus\":\""+std::string(fetch?"i":"d")+"\",\"tag\":"+std::to_string(owner.tag)+
            ",\"reply\":"+std::to_string(owner.reply)+",\"status\":"+std::to_string(owner.status));
    }

    /* each response must retain the accepted result and its original tag under backpressure. */
    void response(Owner &owner,bool valid,bool ready,uint32_t tag,uint32_t value,unsigned error,bool fetch) {
        /* absence before the programmed availability edge is also checked. */
        if (!valid) {
            check(!owner.accepted || clocks-owner.accepted_at<owner.response,"late local response");return;
        }
        check(owner.valid && owner.accepted,"unowned response");
        check(clocks-owner.accepted_at>=owner.response,"early local response");
        check(tag==owner.tag && error==owner.status && value==owner.reply,"response data, error or tag mismatch");
        /* parcel masks and fault attribution belong to the original instruction request. */
        if (fetch) check(dut.i_rsp_parcels_o==owner.parcels && dut.i_rsp_fault_o==(owner.status?owner.parcels:0),"instruction response metadata");
        owner.response_seen=true;
        /* only a handshake releases the independently tracked request owner. */
        if (ready) {
            record("\"event\":\"response\",\"bus\":\""+std::string(fetch?"i":"d")+"\",\"tag\":"+std::to_string(tag));owner=Owner{};
        }
    }

public:
    /* ROM executes startup; no testbench zeroing or fabricated register writes are performed. */
    Machine(char **argv):random_state(uint32_t(std::stoul(argv[5]))^0x6d2b79f5u),stress(std::string(argv[7])=="stress") {
        load(argv[1],rom);load(argv[2],iram);load(argv[3],dram);
        std::ifstream layout(argv[8]);layout>>std::hex>>startup_pc>>data_start>>data_end>>data_load>>bss_start>>bss_end>>boot_marker;
        check(bool(layout),"missing startup layout");
        trace.open(argv[4]);check(bool(trace),"capture open failed");trace<<"{\"schema\":\"DRG5-ARCH1\"}\n";
        defined[0]=true;dut.clk_i=0;dut.reset_i=1;dut.isolated_i=1;dut.permit_i=0;dut.hold_i=0;
        dut.event_set_i=0;dut.block_ready_i=0;dut.i_accept_delay_i=0;dut.d_accept_delay_i=0;
        dut.i_response_delay_i=1;dut.d_response_delay_i=1;
        /* qualified whole-platform reset leaves initialized memories and poison RAM intact. */
        for (unsigned n=0;n<4;++n) {dut.clk_i=0;dut.eval();dut.clk_i=1;dut.eval();}
        dut.reset_i=0;dut.isolated_i=0;dut.permit_i=1;
    }

    /* drive only environmental schedules; all memories and responses are actual RTL. */
    void tick() {
        dut.clk_i=0;dut.permit_i=!finished;
        uint32_t choice=random_word();dut.hold_i=finished?31:stress && (choice&7)==0?uint8_t(1u<<((choice>>3)%5)):0;
        dut.i_accept_delay_i=stress?random_word()%8:0;dut.d_accept_delay_i=stress?random_word()%8:0;
        dut.i_response_delay_i=stress?1+random_word()%12:1;dut.d_response_delay_i=stress?1+random_word()%12:1;
        bool pin=external_due && !external_sent;dut.event_set_i=pin?2:0;
        /* physical bit two is latched once even if software is masked or asleep. */
        if (pin) external_sent=true;
        hold_bins|=dut.hold_i;dut.eval();
        offer(instruction,dut.i_req_valid_o,dut.i_req_addr_o,0,dut.i_req_tag_o,false,2,0,dut.i_req_parcels_o,
            dut.i_accept_delay_i,dut.i_response_delay_i,"i");
        offer(data,dut.d_req_valid_o,dut.d_req_addr_o,dut.d_req_wdata_o,dut.d_req_tag_o,dut.d_req_write_o,
            dut.d_req_size_o,dut.d_req_wstrb_o,0,dut.d_accept_delay_i,dut.d_response_delay_i,"d");
        bool ia=dut.i_req_valid_o&&dut.i_req_ready_o,da=dut.d_req_valid_o&&dut.d_req_ready_o;
        check(!(ia && da && data.write && data.address>=0x10000 && data.address<0x20000 &&
            instruction.address>=0x10000 && instruction.address<0x20000),"IRAM write arbitration");
        bool expected_status=da&&data.write&&data.address==0x40000000;
        bool expected_output=da&&data.write&&data.address==0x40000004;
        /* responses sampled before this edge cannot consume a newly accepted owner. */
        response(instruction,dut.i_rsp_valid_o,dut.i_rsp_ready_o,dut.i_rsp_tag_o,dut.i_rsp_data_o,dut.i_rsp_status_o,true);
        response(data,dut.d_rsp_valid_o,dut.d_rsp_ready_o,dut.d_rsp_tag_o,dut.d_rsp_rdata_o,dut.d_rsp_status_o,false);
        /* simultaneous I reads and D writes use the fabric's declared arbitration. */
        if (ia) accept(instruction,true);
        if (da) accept(data,false);
        uint64_t previous_timer=timer;++timer;
        /* accepted timer writes override the ordinary increment or source state once. */
        if (da && data.write && !data.status) {
            /* each half-write changes precisely its addressed half. */
            switch (data.address) {
                case 0x40001000:timer=(previous_timer&0xffffffff00000000ull)|data.data;break;
                case 0x40001004:timer=(uint64_t(data.data)<<32)|uint32_t(previous_timer);break;
                case 0x40001008:compare=(compare&0xffffffff00000000ull)|data.data;break;
                case 0x4000100c:compare=(uint64_t(data.data)<<32)|uint32_t(compare);break;
                case 0x40001010:software=data.data&1;break;
                case 0x40001014:pending&=~(data.data&~1u);break;
                case 0x40001018:enabled=data.data;break;
                default:break;
            }
        }
        if (pin) pending|=4;
        dut.clk_i=1;dut.eval();++clocks;
        check(dut.status_write_o==expected_status && dut.output_valid_o==expected_output,"duplicate or missing output effect");
        check(dut.status_o==status && dut.output_data_o==output,"output register mismatch");
        check(dut.mtime_o==timer && dut.ext_pending_o==pending && dut.ext_enable_o==enabled,"timer or retained interrupt mismatch");
        idle_clocks+=dut.idle_o;
        /* terminal state must agree with the independently maintained register history. */
        if (field(TRACE_VALID_LSB,1)) {
            check(!finished,"retirement after result boundary");bool trap=field(TRACE_TRAP_LSB,1);uint64_t uid=field(TRACE_UID_LSB,64);
            check(field(TRACE_ORDER_LSB,64)==order && (!order || uid>last_uid),"terminal order");++order;last_uid=uid;
            /* verify initialization independently before the first compiled C call. */
            if (!startup_checked && field(TRACE_PC_LSB,32)==startup_pc) {
                check(!trap && stack_ready,"startup entry or stack");
                /* every initialized word must be explicitly copied from its load address. */
                for(uint32_t address=data_start;address<data_end;address+=4)
                    check(written[(address-0x20000000)/4] && word(address)==word(data_load+address-data_start),"startup data initialization");
                /* the only nonzero BSS object is the marker written after both loops. */
                for(uint32_t address=bss_start;address<bss_end;address+=4)
                    check(written[(address-0x20000000)/4] && word(address)==(address==boot_marker?0xb007d00du:0),"startup BSS initialization");
                startup_checked=true;
            }
            /* uninitialized registers may be saved, but their observed value cannot change silently. */
            for (unsigned n=0;n<2;++n) {
                unsigned index=unsigned(field(n?TRACE_RS2_LSB:TRACE_RS1_LSB,5));
                uint32_t value=uint32_t(field(n?TRACE_RS2_VALUE_LSB:TRACE_RS1_VALUE_LSB,32));
                /* only actual operands participate; unused instruction fields are irrelevant. */
                if (field(n?TRACE_RS2_USED_LSB:TRACE_RS1_USED_LSB,1)) {
                    /* saving an unreset register records its actual value without inventing zero. */
                    if (!defined[index]) {defined[index]=true;registers[index]=value;++unknown_sources;}
                    check(registers[index]==value,"operand history mismatch");
                }
            }
            if (trap) ++traps;else ++retired;
            /* architectural writes may never target x0 or come from a trapping instruction. */
            if (field(TRACE_RD_WRITE_LSB,1)) {
                unsigned rd=unsigned(field(TRACE_RD_LSB,5));uint32_t value=uint32_t(field(TRACE_VALUE_LSB,32));
                check(rd && !trap,"illegal destination update");registers[rd]=value;defined[rd]=true;
                /* the measured stack low-water mark includes full interrupt frames. */
                if (rd==2) {
                    /* the boot address materialization may use a temporary partial value. */
                    if (value==0x20008000) stack_ready=true;
                    /* after initialization, standard-ABI code retains aligned bounded frames. */
                    if (stack_ready) {check((value&15)==0 && value>=0x20007000 && value<=0x20008000,"stack bounds or alignment");if(value<minimum_sp)minimum_sp=value;}
                }
            }
            std::ostringstream packed;
            /* retain the complete terminal record for a separate Python replay. */
            for (int n=TRACE_WORDS-1;n>=0;--n) packed<<std::hex<<std::setw(8)<<std::setfill('0')<<dut.trace_o[n];
            std::string row="\"event\":\"terminal\",\"pc\":"+std::to_string(field(TRACE_PC_LSB,32))+",\"trap\":"+std::to_string(trap)+",\"packed\":\""+packed.str()+"\"";
            record(row);history.push_back(row);if(history.size()>32)history.pop_front();
            if(completion && !trap && field(TRACE_PACKET_OP_LSB,4)==2 && field(TRACE_MEM_ADDR_LSB,32)==0x40000000 && !data.valid)finished=true;
        }
        /* interrupts are separate boundaries, not ordinary retired instructions. */
        if (dut.irq_event_o[3]&1) {
            ++irqs;record("\"event\":\"irq\",\"pc\":"+std::to_string(dut.irq_event_o[2])+",\"cause\":"+std::to_string(dut.irq_event_o[1])+",\"next_pc\":"+std::to_string(dut.irq_event_o[0]));
        }
        check(!dut.fatal_o,"RTL fatal containment");
    }

    /* a committed result ends the program only after every exposed transaction drains. */
    int run(uint64_t limit) {
        /* preserve the last terminal window for any failed self-test or independent check. */
        try {
            while(!finished && clocks<limit)tick();check(finished,"cycle limit without result retirement");
            /* younger work freezes while accepted fetches retain their responses. */
            for(unsigned n=0;n<128 && (instruction.valid || data.valid || dut.i_req_valid_o || dut.d_req_valid_o);++n)tick();
            check(!instruction.valid && !data.valid && !dut.i_req_valid_o && !dut.d_req_valid_o,"result drain exceeded bound");
            check(result==1,"firmware result "+std::to_string(result)+" console="+console);
            check(external_sent && stack_ready && startup_checked && status_writes==1 && outputs>0,"missing platform exercise");
            trace<<"{\"end\":true,\"events\":"<<events<<",\"cycles\":"<<clocks<<",\"retired\":"<<retired<<",\"traps\":"<<traps<<",\"irqs\":"<<irqs
                <<",\"i_accepts\":"<<instruction_accepts<<",\"d_accepts\":"<<data_accepts<<",\"mmio_reads\":0,\"mmio_writes\":0}\n";
            std::cout<<"CONSOLE "<<console<<"\nLOCAL_PLATFORM_PASS {\"cycles\":"<<clocks<<",\"retired\":"<<retired<<",\"traps\":"<<traps
                <<",\"irqs\":"<<irqs<<",\"i_accepts\":"<<instruction_accepts<<",\"d_accepts\":"<<data_accepts<<",\"outputs\":"<<outputs
                <<",\"idle_clocks\":"<<idle_clocks<<",\"unknown_registers_observed\":"<<unknown_sources<<",\"stack_bytes\":"<<(0x20008000-minimum_sp)
                <<",\"acceptance_bins\":"<<acceptance_bins<<",\"response_bins\":"<<response_bins<<",\"hold_bins\":"<<hold_bins<<"}\n";return 0;
        /* no failing capture receives a success footer. */
        } catch(const std::exception &error) {
            std::cerr<<"LOCAL_PLATFORM_FAILURE "<<error.what()<<" cycle="<<clocks<<" mepc="<<dut.mepc_o<<" mcause="<<dut.mcause_o<<" mtval="<<dut.mtval_o
                <<" fetch_reason="<<unsigned(dut.fetch_fatal_reason_o)<<" core_reason="<<((dut.core_fatal_record_o[6]>>7)&7)<<"\n";
            for(const auto &line:history)std::cerr<<line<<"\n";return 1;
        }
    }
};

/* one process starts from explicitly randomized unreset state and one immutable image pair. */
int main(int argc,char **argv) {
    /* initialization randomness must be selected before constructing the RTL model. */
    try {
        check(argc==9,"usage: simulator rom iram poison trace seed cycles local-or-stress layout");
        Verilated::commandArgs(argc,argv);Verilated::randSeed(int(std::stoul(argv[5])));Verilated::randReset(2);
        Machine machine(argv);return machine.run(std::stoull(argv[6]));
    /* configuration errors cannot be confused with firmware success. */
    } catch(const std::exception &error) {std::cerr<<"LOCAL_PLATFORM_FAILURE "<<error.what()<<"\n";return 1;}
}
