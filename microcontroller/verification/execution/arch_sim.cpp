/* execute ELF bytes through production buses and retain independent physical-effect records. */
#include "Vdrg5_arch_top.h"
#include "verilated.h"
#include "arch_trace_fields.h"
#include <array>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

/* one descriptor survives arbitrary independent acceptance and response delays. */
struct Owner {
    bool valid=false, accepted=false, write=false;
    uint32_t address=0, data=0, tag=0, reply=0;
    unsigned size=0, lanes=0, parcels=0, age=0, response_age=0, accept_delay=0, response_delay=0, status=0;
};

/* the model checks transaction ownership without deriving effects from retirement. */
class Machine {
    Vdrg5_arch_top dut;
    std::array<uint8_t,8192> rom{};
    std::array<uint8_t,65536> iram{};
    std::array<uint8_t,32768> dram{};
    std::array<uint32_t,32> registers{};
    std::array<bool,32> defined{};
    Owner instruction, data;
    std::ofstream trace;
    bool full_trace=false, completion=false, finished=false;
    uint32_t random_state, result=0, completion_tag=0;
    uint64_t clocks=0, events=0, retired=0, traps=0, irqs=0, order=0, last_uid=0;
    uint64_t instruction_effects=0, data_effects=0, reads=0, writes=0, digest=1469598103934665603ull;
    unsigned acceptance_bins=0, response_bins=0, hold_bins=0;
    std::array<std::string,32> history;
    unsigned history_index=0;

    /* xorshift timing is reproducible independently of instruction generation. */
    uint32_t random_word() {
        random_state^=random_state<<13; random_state^=random_state>>17; random_state^=random_state<<5;
        return random_state;
    }

    /* invalid loader addresses are rejected instead of silently extending physical RAM. */
    uint8_t &byte(uint32_t address) {
        if (address<rom.size()) return rom[address];
        if (address>=0x10000 && address<0x20000) return iram[address-0x10000];
        if (address>=0x20000000 && address<0x20008000) return dram[address-0x20000000];
        throw std::runtime_error("image outside declared memory");
    }

    /* a physical read assembles little-endian byte lanes. */
    uint32_t read_word(uint32_t address) {
        uint32_t result_word=0;
        for (unsigned lane=0;lane<4;++lane) result_word|=uint32_t(byte((address&~3u)+lane))<<(8*lane);
        return result_word;
    }

    /* a physical write applies only the enabled lanes. */
    void write_word(uint32_t address,uint32_t value,unsigned lanes) {
        /* apply each enabled little-endian lane. */
        for (unsigned lane=0;lane<4;++lane) {
            if (lanes&(1u<<lane)) byte((address&~3u)+lane)=uint8_t(value>>(8*lane));
        }
    }

    /* use explicit schema offsets rather than compiler-dependent structure layout. */
    uint64_t field(unsigned lsb,unsigned width) {
        uint64_t value=0;
        for (unsigned bit=0;bit<width;++bit) value|=uint64_t((dut.trace_o[(lsb+bit)/32]>>((lsb+bit)%32))&1)<<bit;
        return value;
    }

    /* missing trace tails are distinguishable from a valid complete program. */
    void record(const std::string &payload) {
        ++events;
        if (full_trace) trace<<"{\"sequence\":"<<events<<",\"cycle\":"<<clocks<<","<<payload<<"}\n";
    }

    /* a stalled offer cannot disappear, change descriptor or overlap another owner. */
    void offer(Owner &owner,bool valid,uint32_t address,uint32_t value,uint32_t tag,
               bool write,unsigned size,unsigned lanes,unsigned parcels,const char *name) {
        if (owner.valid && !owner.accepted && !valid) throw std::runtime_error("withdrawn offer");
        if (owner.valid && owner.accepted && valid) throw std::runtime_error("overlapping offer");
        /* reserve one descriptor before exposing acceptance. */
        if (valid && !owner.valid) {
            owner=Owner{}; owner.valid=true; owner.address=address; owner.data=value; owner.tag=tag;
            owner.write=write; owner.size=size; owner.lanes=lanes; owner.parcels=parcels;
            owner.accept_delay=random_word()%8; owner.response_delay=1+random_word()%12;
            acceptance_bins|=1u<<owner.accept_delay; response_bins|=1u<<owner.response_delay;
            record("\"event\":\"offer\",\"bus\":\""+std::string(name)+"\",\"address\":"+std::to_string(address)+
                   ",\"tag\":"+std::to_string(tag)+",\"write\":"+std::to_string(write)+",\"data\":"+std::to_string(value)+
                   ",\"size\":"+std::to_string(size)+",\"lanes\":"+std::to_string(lanes));
        }
        if (valid && (owner.address!=address || owner.data!=value || owner.tag!=tag || owner.write!=write ||
            owner.size!=size || owner.lanes!=lanes || owner.parcels!=parcels)) throw std::runtime_error("unstable offer");
    }

    /* target effects occur at acceptance exactly once and are retained until response. */
    void accept(Owner &owner,bool fetch,uint32_t platform_data,bool platform_error) {
        owner.accepted=true; owner.response_age=0; owner.reply=0; owner.status=0;
        /* ordinary memory effects use the loaded byte arrays. */
        if (fetch || owner.address<0x2000 || (owner.address>=0x10000 && owner.address<0x20000) ||
                (owner.address>=0x20000000 && owner.address<0x20008000)) {
            if (owner.write) write_word(owner.address,owner.data,owner.lanes);
            else owner.reply=read_word(owner.address);
        /* timer replies are sampled from the independently clocked platform. */
        } else if (owner.address>=0x40001000 && owner.address<0x40002000) {
            owner.reply=platform_data; owner.status=platform_error?1:0;
        /* record one completion store without stopping before retirement. */
        } else if (owner.address==0x40000000 && owner.write) {
            if (completion) throw std::runtime_error("duplicate completion effect");
            completion=true; completion_tag=owner.tag; result=owner.data;
        /* console writes emit the low byte. */
        } else if (owner.address==0x40000004 && owner.write) {
            std::cout<<char(owner.data&255);
        /* the signature adapter register accepts a harmless write. */
        } else if (owner.address==0x40000008 && owner.write) {
            owner.reply=0;
        /* a destructive read increments its independent effect count. */
        } else if (owner.address==0x40000020 && !owner.write) {
            owner.reply=uint32_t(++reads);
        /* a destructive write increments its independent effect count. */
        } else if (owner.address==0x40000024 && owner.write) {
            ++writes;
        /* observe the read count without another destructive read. */
        } else if (owner.address==0x40000028 && !owner.write) {
            owner.reply=uint32_t(reads);
        /* observe the write count without another destructive write. */
        } else if (owner.address==0x4000002c && !owner.write) {
            owner.reply=uint32_t(writes);
        /* unimplemented device operations return a definite no-effect error. */
        } else {
            owner.status=1;
        }
        /* instruction reads return only the requested parcels. */
        if (fetch) {
            ++instruction_effects;
            owner.reply&=(owner.parcels&1?0xffffu:0)|(owner.parcels&2?0xffff0000u:0);
        /* data reads preserve only the requested physical byte lanes. */
        } else {
            ++data_effects;
            uint32_t mask=owner.size==0?0xffu:owner.size==1?0xffffu:0xffffffffu;
            owner.reply=owner.write || owner.status?0:owner.reply&(mask<<(8*(owner.address&3)));
        }
        record("\"event\":\"accept\",\"bus\":\""+std::string(fetch?"i":"d")+"\",\"tag\":"+std::to_string(owner.tag)+
               ",\"reply\":"+std::to_string(owner.reply)+",\"status\":"+std::to_string(owner.status));
    }

public:
    /* ROM initialization is executed by the CPU, never fabricated as reset register contents. */
    Machine(const std::string &image,const std::string &capture,uint32_t seed):random_state(seed?seed:0x6d2b79f5) {
        std::ifstream input(image);
        if (!input) throw std::runtime_error("missing memory image");
        uint32_t address,value;
        while (input>>std::hex>>address>>value) byte(address)=uint8_t(value);
        defined[0]=true;
        full_trace=capture!="-";
        /* write a capture header before any event. */
        if (full_trace) {
            trace.open(capture); if (!trace) throw std::runtime_error("capture open failed");
            trace<<"{\"schema\":\"DRG5-ARCH1\",\"seed\":"<<seed<<"}\n";
        }
        dut.clk_i=0; dut.reset_i=1; dut.permit_i=0; dut.hold_i=0;
        /* hold reset for four complete core clocks. */
        for (unsigned n=0;n<4;++n) {dut.clk_i=0;dut.eval();dut.clk_i=1;dut.eval();}
        dut.reset_i=0; dut.permit_i=1;
    }

    /* sampled target inputs settle before each edge; consumed replies clear after it. */
    void tick() {
        dut.clk_i=0;
        uint32_t choice=random_word(); dut.hold_i=finished?31:((choice&7)==0?uint8_t(1u<<((choice>>3)%5)):0);
        dut.permit_i=!finished;
        hold_bins|=dut.hold_i; dut.eval();
        offer(instruction,dut.i_req_valid_o,dut.i_req_addr_o,0,dut.i_req_tag_o,false,2,0,dut.i_req_parcels_o,"i");
        offer(data,dut.d_req_valid_o,dut.d_req_addr_o,dut.d_req_wdata_o,dut.d_req_tag_o,dut.d_req_write_o,
              dut.d_req_size_o,dut.d_req_wstrb_o,0,"d");
        dut.i_req_ready_i=instruction.valid && !instruction.accepted && instruction.age>=instruction.accept_delay;
        dut.d_req_ready_i=data.valid && !data.accepted && data.age>=data.accept_delay;
        dut.i_rsp_valid_i=instruction.accepted && instruction.response_age>=instruction.response_delay;
        dut.i_rsp_tag_i=instruction.tag;dut.i_rsp_data_i=instruction.reply;dut.i_rsp_parcels_i=instruction.parcels;
        dut.i_rsp_fault_i=instruction.status?instruction.parcels:0;dut.i_rsp_status_i=instruction.status;
        dut.d_rsp_valid_i=data.accepted && data.response_age>=data.response_delay;
        dut.d_rsp_tag_i=data.tag;dut.d_rsp_rdata_i=data.reply;dut.d_rsp_status_i=data.status;
        dut.eval();
        bool ia=dut.i_req_valid_o&&dut.i_req_ready_i, da=dut.d_req_valid_o&&dut.d_req_ready_i;
        bool ir=dut.i_rsp_valid_i&&dut.i_rsp_ready_o, dr=dut.d_rsp_valid_i&&dut.d_rsp_ready_o;
        uint32_t platform_data=dut.platform_rdata_o;bool platform_error=dut.platform_error_o;
        dut.clk_i=1;dut.eval();++clocks;
        if (ia) accept(instruction,true,0,false);
        if (da) accept(data,false,platform_data,platform_error);
        /* release the instruction descriptor only after captured response. */
        if (ir) {
            record("\"event\":\"response\",\"bus\":\"i\",\"tag\":"+std::to_string(instruction.tag));
            instruction=Owner{};dut.i_rsp_valid_i=0;
        }
        /* release the data descriptor only after captured response. */
        if (dr) {
            record("\"event\":\"response\",\"bus\":\"d\",\"tag\":"+std::to_string(data.tag));
            data=Owner{};dut.d_rsp_valid_i=0;
        }
        dut.eval();
        /* age each surviving request independently of pipeline progress. */
        for (Owner *owner:{&instruction,&data}) {
            /* accepted owners also age their response delay. */
            if (owner->valid) {++owner->age;if(owner->accepted)++owner->response_age;}
        }
        /* check terminal order and architectural operand history. */
        if (field(TRACE_VALID_LSB,1)) {
            if (finished) throw std::runtime_error("retirement after completion boundary");
            bool trap=field(TRACE_TRAP_LSB,1);
            uint64_t uid=field(TRACE_UID_LSB,64);
            if (field(TRACE_ORDER_LSB,64)!=order || (order && uid<=last_uid)) throw std::runtime_error("retirement order");
            ++order;last_uid=uid;
            /* verify each used source against prior committed state. */
            for (unsigned operand=0;operand<2;++operand) {
                unsigned used=operand?TRACE_RS2_USED_LSB:TRACE_RS1_USED_LSB;
                unsigned index=unsigned(field(operand?TRACE_RS2_LSB:TRACE_RS1_LSB,5));
                uint32_t actual=uint32_t(field(operand?TRACE_RS2_VALUE_LSB:TRACE_RS1_VALUE_LSB,32));
                if (field(used,1) && (!defined[index] || registers[index]!=actual)) throw std::runtime_error("operand history");
            }
            if (trap) ++traps; else ++retired;
            /* update independent register history only for a legal destination. */
            if (field(TRACE_RD_WRITE_LSB,1)) {
                unsigned rd=unsigned(field(TRACE_RD_LSB,5));
                if (!rd || trap) throw std::runtime_error("illegal destination update");
                registers[rd]=uint32_t(field(TRACE_VALUE_LSB,32));defined[rd]=true;
            }
            std::ostringstream packed;
            /* serialize the complete terminal payload without host layout assumptions. */
            for (int word=TRACE_WORDS-1;word>=0;--word) {
                packed<<std::hex<<std::setw(8)<<std::setfill('0')<<dut.trace_o[word];
                digest=(digest^dut.trace_o[word])*1099511628211ull;
            }
            std::string terminal="\"event\":\"terminal\",\"pc\":"+std::to_string(field(TRACE_PC_LSB,32))+
                ",\"trap\":"+std::to_string(trap)+",\"packed\":\""+packed.str()+"\"";
            record(terminal);history[history_index++%history.size()]=terminal;
            if (completion && field(TRACE_MEM_ADDR_LSB,32)==0x40000000 && !trap &&
                    field(TRACE_PACKET_OP_LSB,4)==2 && !data.valid) finished=true;
        }
        /* record interrupt entry separately from instruction retirement. */
        if (dut.irq_event_o[3]&1) {
            ++irqs;record("\"event\":\"irq\",\"pc\":"+std::to_string(dut.irq_event_o[2])+
                ",\"cause\":"+std::to_string(dut.irq_event_o[1])+",\"next_pc\":"+std::to_string(dut.irq_event_o[0]));
        }
        if (dut.fatal_o) throw std::runtime_error("RTL fatal containment");
    }

    /* only a retired completion store can end execution; an instruction limit is failure. */
    int run(uint64_t limit) {
        /* require architectural completion within the execution bound. */
        try {
            while (!finished && clocks<limit) tick();
            if (!finished) throw std::runtime_error("cycle limit without completion");
            /* freeze younger stages while every exposed request finishes its response. */
            for (unsigned drain=0;drain<128;++drain) {
                tick();
                if (!instruction.valid && !data.valid && !dut.i_req_valid_o && !dut.d_req_valid_o) break;
            }
            if (instruction.valid || data.valid || dut.i_req_valid_o || dut.d_req_valid_o)
                throw std::runtime_error("completion drain exceeded bound");
            if (result!=1) throw std::runtime_error("architectural test reported failure "+std::to_string(result));
            if (full_trace) trace<<"{\"end\":true,\"events\":"<<events<<",\"cycles\":"<<clocks<<",\"retired\":"<<retired
                <<",\"traps\":"<<traps<<",\"irqs\":"<<irqs<<",\"i_accepts\":"<<instruction_effects
                <<",\"d_accepts\":"<<data_effects<<",\"mmio_reads\":"<<reads<<",\"mmio_writes\":"<<writes<<"}\n";
            std::cout<<"\nARCH_EXEC_PASS {\"cycles\":"<<clocks<<",\"retired\":"<<retired<<",\"traps\":"<<traps
                <<",\"irqs\":"<<irqs<<",\"i_accepts\":"<<instruction_effects<<",\"d_accepts\":"<<data_effects
                <<",\"mmio_reads\":"<<reads<<",\"mmio_writes\":"<<writes<<",\"digest\":"<<digest
                <<",\"acceptance_bins\":"<<acceptance_bins<<",\"response_bins\":"<<response_bins<<",\"hold_bins\":"<<hold_bins<<"}\n";
            return 0;
        /* retain the last terminal window when an ordinary check fails. */
        } catch (const std::exception &error) {
            std::cerr<<"ARCH_EXEC_FAILURE "<<error.what()<<" cycle="<<clocks<<" mepc="<<dut.mepc_o
                     <<" mcause="<<dut.mcause_o<<" mtval="<<dut.mtval_o<<" completion_tag="<<completion_tag<<"\n";
            for (unsigned n=0;n<history.size();++n) std::cerr<<history[(history_index+n)%history.size()]<<"\n";
            return 1;
        }
    }
};

/* one process executes one immutable image and reproducible memory schedule. */
int main(int argc,char **argv) {
    /* validate one invocation before constructing the simulated machine. */
    try {
        if (argc!=5) throw std::runtime_error("usage: simulator image trace-or-dash seed max-cycles");
        Verilated::commandArgs(argc,argv);
        Machine machine(argv[1],argv[2],uint32_t(std::stoul(argv[3])));
        return machine.run(std::stoull(argv[4]));
    /* report loader or configuration failures without a success footer. */
    } catch (const std::exception &error) {
        std::cerr<<"ARCH_EXEC_FAILURE "<<error.what()<<"\n";return 1;
    }
}
