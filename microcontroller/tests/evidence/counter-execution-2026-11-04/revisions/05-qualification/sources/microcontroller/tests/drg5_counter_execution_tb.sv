/* compare machine counters with independent clock and architectural execution records. */
module drg5_counter_execution_tb #(parameter bit C_ENABLED=1, DIAGNOSTIC=0, FORWARDING=1);
  import drg5_control_pkg::*;
  localparam bit M_ENABLED=1;
  localparam int WORDS=4096, CAPACITY=1024;
  localparam int NOP=0, ADDI=1, LUI=2, CSR=3, LOAD=4, DIVIDE=5, FENCE=6, FENCEI=7,
      WFI=8, MRET=9, TRAP=10;
  /* original instruction intent is independent of DUT decode and retirement metadata. */
  typedef struct packed {
    bit present;
    logic [31:0] raw;
    int length, operation, rd, rs1;
    logic [31:0] immediate;
    logic [11:0] address;
    int form;
    logic [31:0] cause, tval;
  } instruction_t;
  instruction_t program_ref [0:WORDS-1];
  logic [15:0] image [0:WORDS-1];
  logic [31:0] regs_ref [0:31];
  bit defined_ref [0:31], live [0:CAPACITY-1];
  packet_t original [0:CAPACITY-1];
  logic clk_i=0, cold_reset_i=0, hart_reset_i=0, run_enable=0;
  logic [4:0] hold_i=0;
  logic in_valid_i, in_ready_o, frontend_ready;
  packet_t in_packet_i;
  logic entry_pending_o, idle_o, irq_valid_o;
  logic [31:0] manual_levels=0;
  logic [31:0] irq_pc_o, irq_cause_o;
  logic flush_ready_o, flush_aborted_o, redirect_valid_o;
  logic [31:0] redirect_pc_o;
  logic i_req_valid_o, i_req_ready_i, i_rsp_valid_i, i_rsp_ready_o;
  logic [31:0] i_req_addr_o, i_req_tag_o, i_rsp_tag_i, i_rsp_data_i;
  logic [1:0] i_req_parcels_o, i_rsp_parcels_i, i_rsp_fault_i, i_rsp_status_i;
  logic fetch_busy, fetch_discard, fetch_fatal, fetch_launch, fetch_accept, fetch_complete, fetch_drop;
  logic [2:0] fetch_reason;
  logic [1:0] fetch_generation, insn_generation;
  logic d_req_valid_o, d_req_ready_i, d_req_write_o, d_rsp_valid_i, d_rsp_ready_o;
  logic [31:0] d_req_addr_o, d_req_wdata_o, d_req_tag_o, d_rsp_tag_i, d_rsp_rdata_i;
  logic [1:0] d_req_size_o, d_rsp_status_i;
  logic [3:0] d_req_wstrb_o;
  logic mem_launch_o, mem_busy_o, fatal_o;
  fatal_record_t fatal_record_o;
  logic [4:0] stage_valid_o, kill_valid_o;
  token_t stage_token_o [0:4];
  logic [3:0] transfer_o;
  logic [63:0] kill_uid_o [0:4];
  trace_t trace_o;
  logic [31:0] inspect_value_o, mstatus_o, mtvec_o, mscratch_o, mepc_o, mcause_o, mtval_o;
  logic inspect_defined_o;
  logic [31:0] mie_o, mip_o, mcountinhibit_o;
  logic [63:0] mcycle_o, minstret_o;
  wire unused_ports = ^{fetch_generation, insn_generation, fetch_discard, mem_launch_o, fatal_record_o, trace_o.csr_old, trace_o.csr_new, trace_o.csr_read, trace_o.csr_write, transfer_o, inspect_value_o, inspect_defined_o,
      mstatus_o, mtvec_o, mscratch_o, mie_o, mip_o, mcountinhibit_o, mcycle_o, minstret_o,
      flush_ready_o, flush_aborted_o, irq_pc_o, irq_cause_o, fetch_launch, fetch_accept, fetch_complete,
      fetch_reason, d_req_wdata_o, trace_o, stage_token_o[0], stage_token_o[1], stage_token_o[2], stage_token_o[3], stage_token_o[4]};
  logic frontend_valid;
  assign in_valid_i = frontend_valid && run_enable;
  assign frontend_ready = in_ready_o && run_enable;

  /* use the production fetch/packet adapter with a finite stress deadline. */
  drg5_frontend #(.C_ENABLED(C_ENABLED), .GEN_BITS(2), .MAX_WAIT_CYCLES(128), .TEST_REGIONS(1)) frontend (
    .clk_i(clk_i), .cold_reset_i(cold_reset_i), .isolated_i(1'b1), .hart_reset_i(hart_reset_i),
    .permit_i(run_enable), .entry_pending_i(entry_pending_o), .core_fatal_i(fatal_o),
    .redirect_valid_i(redirect_valid_o), .redirect_pc_i(redirect_pc_o),
    .i_req_valid_o, .i_req_ready_i, .i_req_addr_o, .i_req_tag_o, .i_req_parcels_o,
    .i_rsp_valid_i, .i_rsp_ready_o, .i_rsp_tag_i, .i_rsp_data_i, .i_rsp_parcels_i, .i_rsp_fault_i, .i_rsp_status_i,
    .insn_valid_o(frontend_valid), .insn_ready_i(frontend_ready), .insn_packet_o(in_packet_i),
    .busy_o(fetch_busy), .discard_o(fetch_discard), .fatal_o(fetch_fatal), .fatal_reason_o(fetch_reason),
    .generation_o(fetch_generation), .insn_generation_o(insn_generation), .launch_o(fetch_launch), .accept_o(fetch_accept),
    .complete_o(fetch_complete), .drop_o(fetch_drop)
  );

  /* exercise the same raw machine decoder with independent ISA and occupancy choices. */
  drg5_control #(.C_ENABLED(C_ENABLED), .M_ENABLED(M_ENABLED), .DIAGNOSTIC(DIAGNOSTIC),
      .FORWARDING(FORWARDING), .ZIFENCEI_ENABLED(1), .IRAM_WRITE(1), .IRQ_ENABLED(1), .TEST_REGIONS(1), .D_MAX_WAIT_CYCLES(128)) dut (
    .clk_i, .cold_reset_i, .isolated_i(1'b1), .hart_reset_i, .mip_levels_i(manual_levels),
    .fetch_busy_i(fetch_busy), .entry_pending_o, .idle_o, .irq_valid_o, .irq_pc_o, .irq_cause_o,
    .hold_i, .in_valid_i, .in_ready_o, .in_packet_i, .flush_valid_i(1'b0), .flush_ready_o,
    .flush_pc_i(32'b0), .flush_aborted_o, .redirect_valid_o, .redirect_pc_o,
    .d_req_valid_o, .d_req_ready_i, .d_req_addr_o, .d_req_wdata_o, .d_req_write_o, .d_req_size_o,
    .d_req_wstrb_o, .d_req_tag_o, .d_rsp_valid_i, .d_rsp_ready_o, .d_rsp_tag_i, .d_rsp_rdata_i,
    .d_rsp_status_i, .mem_launch_o, .mem_busy_o, .fatal_o, .fatal_record_o, .stage_valid_o,
    .stage_token_o, .transfer_o, .kill_valid_o, .kill_uid_o, .trace_o, .inspect_reg_i(5'b0),
    .inspect_value_o, .inspect_defined_o, .mstatus_o, .mtvec_o, .mscratch_o, .mepc_o,
    .mcause_o, .mtval_o, .mie_o, .mip_o, .mcountinhibit_o, .mcycle_o, .minstret_o
  );


  logic capture_reset_i=1;
  observe_t observation;
  logic [63:0] observer_sequence=0, observer_epoch=0, observer_retired=0;
  bit observer_previous_reset=1;
  int trace_fd=0;
  string trace_path;

  /* the observer is a passive companion; every field is checked against sampled public wires. */
  drg5_observe observer (
    .clk_i, .capture_reset_i, .cold_reset_i, .isolated_i(1'b1), .hart_reset_i,
    .debug_mode_i(1'b0), .debug_ebreak_entry_i(1'b0), .hold_i, .stage_valid_i(stage_valid_o),
    .transfer_i(transfer_o), .stage_token_i(stage_token_o), .in_valid_i, .in_ready_i(in_ready_o), .in_packet_i,
    .mip_levels_i(manual_levels), .mcycle_i(mcycle_o), .minstret_i(minstret_o), .mcountinhibit_i(mcountinhibit_o),
    .trace_i(trace_o), .kill_valid_i(kill_valid_o), .kill_uid_i(kill_uid_o),
    .irq_valid_i(irq_valid_o), .idle_i(idle_o), .fatal_i(fatal_o), .irq_pc_i(irq_pc_o), .irq_cause_i(irq_cause_o),
    .fatal_record_i(fatal_record_o), .redirect_valid_i(redirect_valid_o), .redirect_pc_i(redirect_pc_o),
    .flush_valid_i(1'b0), .flush_ready_i(flush_ready_o), .flush_aborted_i(flush_aborted_o), .flush_pc_i(32'b0),
    .mem_launch_i(mem_launch_o), .d_req_valid_i(d_req_valid_o), .d_req_ready_i(d_req_ready_i),
    .d_req_write_i(d_req_write_o), .d_req_addr_i(d_req_addr_o), .d_req_wdata_i(d_req_wdata_o), .d_req_tag_i(d_req_tag_o),
    .d_req_size_i(d_req_size_o), .d_req_wstrb_i(d_req_wstrb_o), .d_rsp_valid_i, .d_rsp_ready_i(d_rsp_ready_o),
    .d_rsp_tag_i, .d_rsp_rdata_i, .d_rsp_status_i,
    .i_req_valid_i(i_req_valid_o), .i_req_ready_i, .i_req_addr_i(i_req_addr_o), .i_req_tag_i(i_req_tag_o),
    .i_req_parcels_i(i_req_parcels_o), .i_rsp_valid_i, .i_rsp_ready_i(i_rsp_ready_o), .i_drop_i(fetch_drop),
    .i_rsp_tag_i, .i_rsp_data_i, .i_rsp_parcels_i, .i_rsp_fault_i, .i_rsp_status_i,
    .i_fatal_i(fetch_fatal), .i_fatal_reason_i(fetch_reason), .record_o(observation)
  );

  bit i_owned=0, i_accepted=0, i_stale=0, d_owned=0, d_accepted=0;
  logic [31:0] i_address=0, i_tag=0, i_data=0, d_address=0, d_tag=0;
  logic [1:0] i_parcels=0;
  int i_age=0, i_response_age=0, i_accept_delay=0, i_response_delay=0;
  int d_age=0, d_response_age=0;
  int next_uid=0, next_order=0, builder_pc=0, case_edges=0;
  logic [31:0] arch_pc=0, vector_ref=0, epc_ref=0, status_ref=32'h1800, enable_ref=0;
  logic [63:0] cycle_ref=0, instret_ref=0;
  logic [31:0] inhibit_ref=5;
  int seed=0;
  logic [31:0] rng=0;
  bit terminal=0, irq_case=0, mutation_applied=0;
  int wake_ticks=0;
  int cases=0, edges=0, checks=0, retired=0, trapped=0, compressed=0, irq_entries=0, idle_edges=0;
  int counter_reads=0, counter_writes=0, inhibit_writes=0, suppressed_writes=0, retained_zero_writes=0;
  int cycle_rollovers=0, instret_rollovers=0, cycle_wraps=0, instret_wraps=0, held_edges=0, divide_waits=0;
  int i_offers=0, i_accepts=0, i_responses=0, stale_responses=0, d_offers=0, d_accepts=0, d_responses=0;
  int all_forms=0, half_accesses=0;
  logic [31:0] history_pc [0:31];
  logic [63:0] history_cycle [0:31], history_instret [0:31];
  logic [4:0] history_stages [0:31];
  logic [63:0] program_digest=64'hcbf29ce484222325;

  /* service randomness never changes the fixed instruction corpus. */
  function automatic logic [31:0] random_word;
    rng=rng*32'd1664525+32'd1013904223;
    return rng;
  endfunction

  /* counter failures preserve recent clock and execution records for exact reproduction. */
  task automatic check(input bit condition, input string label_text);
    checks++;
    /* stop before another clock can obscure the first divergent update. */
    if (!condition) begin
      $display("COUNTER_EXEC_FAILURE label=%s seed=%0d case=%0d edge=%0d pc=%08x cycle=%016x instret=%016x inhibit=%x",
          label_text,seed,cases,edges,arch_pc,cycle_ref,instret_ref,inhibit_ref);
      $display("COUNTER_FATAL core=%b reason=%0d fetch=%b reason=%0d I=%b/%b tag=%08x addr=%08x data=%08x parcels=%02b drop=%b",
          fatal_o,fatal_record_o.reason,fetch_fatal,fetch_reason,i_owned,i_accepted,i_tag,i_address,i_data,i_parcels,fetch_drop);
      /* recent records include stalls and counter values even on edges with no retirement. */
      for (int n=0;n<32;n++) $display("COUNTER_HISTORY age=%0d pc=%08x cycle=%016x instret=%016x stages=%05b",
          n,history_pc[(edges+n)%32],history_cycle[(edges+n)%32],history_instret[(edges+n)%32],history_stages[(edges+n)%32]);
      $fatal(1,"COUNTER_EXEC_CHECK_FAILED %s",label_text);
    end
  endtask

  /* responders retain one stable descriptor and one registered reply per port. */
  always_comb begin
    i_req_ready_i=i_owned && !i_accepted && i_age>=i_accept_delay && !cold_reset_i;
    i_rsp_valid_i=i_owned && i_accepted && i_response_age>=i_response_delay && !cold_reset_i;
    i_rsp_tag_i=i_tag; i_rsp_data_i=i_data; i_rsp_parcels_i=i_parcels; i_rsp_fault_i=0; i_rsp_status_i=0;
    d_req_ready_i=d_owned && !d_accepted && d_age>=7 && !cold_reset_i;
    d_rsp_valid_i=d_owned && d_accepted && d_response_age>=11 && !cold_reset_i;
    d_rsp_tag_i=d_tag; d_rsp_rdata_i=32'hcafebabe; d_rsp_status_i=0;
  end

  /* place a standard I immediate without importing decoder helpers. */
  function automatic logic [31:0] encode_i(input int unused_opcode, unused_rd, unused_rs1, unused_function,
      input logic [31:0] unused_immediate);
    return {unused_immediate[11:0],5'(unused_rs1),3'(unused_function),5'(unused_rd),7'(unused_opcode)};
  endfunction

  /* program bytes and semantic metadata are constructed together before execution. */
  task automatic emit(input logic [31:0] raw, input int length, operation, rd, rs1, input logic [31:0] immediate=0);
    int index;
    index=builder_pc/2; check(index>=0 && index+1<WORDS,"bounded program construction");
    program_ref[index]='{present:1,raw:raw,length:length,operation:operation,rd:rd,rs1:rs1,
        immediate:immediate,address:0,form:0,cause:0,tval:0};
    image[index]=raw[15:0];
    /* wide encodings may begin at either halfword with C enabled. */
    if (length==4) image[index+1]=raw[31:16];
    program_digest=(program_digest^{32'(builder_pc),raw})*64'h100000001b3;
    builder_pc+=length;
  endtask

  /* constants initialize every nonzero source register used by the program. */
  task automatic load_constant(input int rd, input logic [31:0] value);
    logic [31:0] upper, lower;
    upper=(value+32'h800)&32'hfffff000; lower=value-upper;
    emit(upper|32'(rd<<7)|32'h37,4,LUI,rd,0,upper);
    emit(encode_i('h13,rd,rd,0,lower),4,ADDI,rd,rd,lower);
  endtask

  /* CSR metadata records the architectural form without observing DUT suppression flags. */
  task automatic emit_csr(input logic [11:0] address, input int form, rd, source_index);
    int index;
    index=builder_pc/2; check(index>=0 && index<WORDS,"bounded CSR location");
    emit({address,5'(source_index),3'(form),5'(rd),7'h73},4,CSR,rd,source_index);
    program_ref[index].address=address; program_ref[index].form=form;
  endtask

  /* write a machine CSR with an explicitly initialized register source. */
  task automatic set_csr(input logic [11:0] address, input logic [31:0] value);
    load_constant(1,value); emit_csr(address,1,0,1);
  endtask

  /* use a real synchronous terminal exception to end a program. */
  task automatic finish_program(input int cause=3, input bit short_break=0);
    int index;
    index=builder_pc/2;
    emit(short_break?32'h00009002:cause==11?32'h00000073:32'h00100073,short_break?2:4,TRAP,0,0);
    program_ref[index].cause=32'(cause); program_ref[index].tval=cause==3?32'(index*2):0;
  endtask

  /* only implemented counter/control CSR values are modeled for the directed corpus. */
  function automatic logic [31:0] csr_value(input logic [11:0] address);
    /* RV32 halves are independently selected from the pre-edge reference value. */
    case (address)
      12'hb00:return cycle_ref[31:0];
      12'hb80:return cycle_ref[63:32];
      12'hb02:return instret_ref[31:0];
      12'hb82:return instret_ref[63:32];
      12'h320:return inhibit_ref;
      12'h300:return status_ref;
      12'h304:return enable_ref;
      12'h305:return vector_ref;
      12'h341:return epc_ref;
      default:return 0;
    endcase
  endfunction

  /* one edge compares actual execution first, then advances the independent counter ledger. */
  initial forever begin : execution_ledger
    bit input_fire, i_accept, i_reply, d_accept, d_reply, pre_redirect, pre_drop, pre_idle;
    bit pre_i_valid, pre_d_valid, normal_retire, csr_read, csr_write, write_rd, pre_fetch_fatal;
    logic [31:0] pre_i_address, pre_i_tag, pre_d_address, pre_d_tag, result_value, next_pc;
    logic [1:0] pre_i_parcels;
    logic [4:0] pre_stages, pre_holds;
    logic [3:0] pre_transfers;
    logic [63:0] pre_cycle, pre_instret, pre_total_retired;
    logic [31:0] pre_inhibit;
    logic [63:0] next_cycle, next_instret, actual_cycle, actual_instret;
    logic [31:0] next_inhibit, old_csr, new_csr, source_value;
    packet_t offered;
    instruction_t expected;
    int index, id, owners;
    @(posedge clk_i);
    pre_fetch_fatal=fetch_fatal; pre_stages=stage_valid_o; pre_holds=hold_i; pre_transfers=transfer_o;
    pre_cycle=cycle_ref; pre_instret=instret_ref; pre_inhibit=inhibit_ref; pre_total_retired=observer_retired;
    input_fire=in_valid_i && in_ready_o; offered=in_packet_i;
    i_accept=i_req_valid_o && i_req_ready_i; i_reply=i_rsp_valid_i && i_rsp_ready_o;
    d_accept=d_req_valid_o && d_req_ready_i; d_reply=d_rsp_valid_i && d_rsp_ready_o;
    pre_i_valid=i_req_valid_o; pre_i_address=i_req_addr_o; pre_i_tag=i_req_tag_o; pre_i_parcels=i_req_parcels_o;
    pre_d_valid=d_req_valid_o; pre_d_address=d_req_addr_o; pre_d_tag=d_req_tag_o;
    pre_redirect=redirect_valid_o; pre_drop=fetch_drop; pre_idle=idle_o;
    #1; edges++; case_edges++;
    history_pc[edges%32]=arch_pc; history_cycle[edges%32]=cycle_ref;
    history_instret[edges%32]=instret_ref; history_stages[edges%32]=stage_valid_o;
    /* reset defines counter state independently of the prior pipeline occupancy. */
    if (cold_reset_i) begin
      cycle_ref=0; instret_ref=0; inhibit_ref=5; arch_pc=0; vector_ref=0; epc_ref=0; status_ref='h1800; enable_ref=0;
      next_uid=0; next_order=0; i_owned=0; i_accepted=0; i_stale=0; d_owned=0; d_accepted=0;
      /* architectural reset does not define general registers other than x0. */
      for (int r=0;r<32;r++) begin regs_ref[r]=0; defined_ref[r]=r==0; end
      /* reset is an explicit abort of every previously live fixture identity. */
      for (int n=0;n<CAPACITY;n++) begin live[n]=0; original[n]='0; end
      check(!trace_o.valid && !irq_valid_o,"reset suppresses terminal events");
    end
    /* each normal edge includes bubbles, request waits and retirement-time CSR operations. */
    else begin
      check(!fatal_o && !pre_fetch_fatal && !fatal_record_o.valid,"unexpected fatal event");
      next_cycle=cycle_ref+64'(!inhibit_ref[0]); next_instret=instret_ref; next_inhibit=inhibit_ref;
      normal_retire=0; csr_read=0; csr_write=0; old_csr=0; new_csr=0; source_value=0;
      idle_edges+=int'(pre_idle); held_edges+=int'(|hold_i);
      /* busy arithmetic is sampled independently of instruction retirement. */
      if (stage_valid_o[2] && stage_token_o[2].md_issued && !stage_token_o[2].md_done) divide_waits++;
      /* redirect invalidation never cancels the physical instruction owner. */
      if (pre_redirect && i_owned) i_stale=1;
      /* an unaccepted request retains all descriptor bits through stalls. */
      if (i_owned && !i_accepted) check(pre_i_valid && pre_i_address==i_address &&
          pre_i_tag==i_tag && pre_i_parcels==i_parcels,"stable I owner");
      /* an accepted request cannot be offered a second time. */
      if (i_owned && i_accepted) check(!pre_i_valid,"single I acceptance");
      /* old replies are consumed exactly once and never restored after a redirect. */
      if (i_reply) begin
        check(i_owned && i_accepted && pre_drop==i_stale,"I response owner and stale disposition");
        stale_responses+=int'(i_stale); i_owned=0; i_accepted=0; i_responses++;
      end
      /* instruction RAM snapshots selected parcels at acceptance. */
      else if (i_accept) begin
        check(i_owned && !i_accepted,"one I acceptance per offer"); i_accepted=1; i_response_age=0; i_data=0; i_accepts++;
        /* unused lanes remain canonical zero values. */
        for (int parcel=0;parcel<2;parcel++) begin
          if (i_parcels[parcel]) i_data[parcel*16+:16]=image[int'(i_address/2)+parcel];
        end
      end
      /* response service continues while the CPU stalls. */
      else if (i_owned && i_accepted) i_response_age++;
      /* acceptance delay is independent of response delay. */
      else if (i_owned) i_age++;
      /* first presentation creates target-side ownership before ready may assert. */
      else if (pre_i_valid) begin
        check(pre_i_address<32'(WORDS*2) && pre_i_address[1:0]==0,"fetch only the side-effect-free ROM");
        i_owned=1; i_accepted=0; i_stale=pre_redirect; i_address=pre_i_address; i_tag=pre_i_tag; i_parcels=pre_i_parcels;
        i_age=0; i_accept_delay=int'(random_word()%4); i_response_delay=1+int'(random_word()%6); i_offers++;
      end
      /* data reads retain their single descriptor through separate acceptance and response waits. */
      if (d_owned && !d_accepted) check(pre_d_valid && pre_d_address==d_address && pre_d_tag==d_tag,"stable D owner");
      if (d_owned && d_accepted) check(!pre_d_valid,"single D acceptance");
      /* the only successful fixture data operation is a naturally aligned RAM read. */
      if (d_reply) begin check(d_owned && d_accepted,"one D response"); d_owned=0; d_accepted=0; d_responses++; end
      /* physical acceptance is counted independently of retirement. */
      else if (d_accept) begin d_accepted=1; d_response_age=0; d_accepts++; end
      /* target service clocks do not inherit CPU stage holds. */
      else if (d_owned && d_accepted) d_response_age++;
      /* the acceptance counter runs until the independently selected delay completes. */
      else if (d_owned) d_age++;
      /* rejected accesses must never become a physical target offer. */
      else if (pre_d_valid) begin
        check(pre_d_address==32'h20000000 && !d_req_write_o && d_req_size_o==2 && d_req_wstrb_o==15,
            "only permitted RAM load reaches target");
        d_owned=1; d_accepted=0; d_address=pre_d_address; d_tag=pre_d_tag; d_age=0; d_offers++;
      end
      /* every accepted raw instruction receives a unique expected owner. */
      if (input_fire) begin
        check(next_uid<CAPACITY,"bounded accepted instruction count"); live[next_uid]=1; original[next_uid]=offered; next_uid++;
      end
      /* redirect and trap kills explicitly dispose each younger instruction. */
      for (int stage=0;stage<5;stage++) begin
        /* each kill consumes an independently live accepted instruction. */
        if (kill_valid_o[stage]) begin
          id=int'(kill_uid_o[stage]); check(id<next_uid && live[id],"one kill per instruction"); live[id]=0;
        end
      end
      /* architectural comparison uses a separately specified program and pre-edge counter state. */
      if (trace_o.valid) begin
        id=int'(trace_o.uid); check(id<next_uid && live[id] && trace_o.order==64'(next_order),"one ordered terminal");
        /* no terminal may skip an older instruction that is still live. */
        for (int older=0;older<id;older++) check(!live[older],"oldest instruction terminal");
        index=int'(arch_pc/2); check(index>=0 && index<WORDS,"bounded architectural PC"); expected=program_ref[index];
        check(expected.present && trace_o.packet.pc==arch_pc && trace_o.packet.raw==expected.raw &&
            trace_o.packet.length==3'(expected.length) && trace_o.packet.raw_valid==4'(expected.length==2?3:15),
            "original instruction and architectural PC");
        check(original[id].pc==trace_o.packet.pc && original[id].raw==trace_o.packet.raw &&
            original[id].length==trace_o.packet.length,"accepted identity preserved");
        result_value=0; write_rd=0; next_pc=arch_pc+32'(expected.length);
        /* faulting instructions never become ordinary retirements or CSR updates. */
        if (expected.operation==TRAP) begin
          check(trace_o.trap && trace_o.packet.cause==expected.cause && trace_o.packet.mtval==expected.tval &&
              mepc_o==arch_pc && mcause_o==expected.cause && mtval_o==expected.tval,"precise trapping instruction");
          check(!trace_o.rd_write && !trace_o.csr_read && !trace_o.csr_write,"trap has no ordinary architectural effects");
          trapped++; terminal=1; run_enable=0; next_pc=vector_ref;
          status_ref=32'h1800|(status_ref[3]?32'h80:0); epc_ref=arch_pc;
        end
        /* successful instructions count exactly once, regardless of original length. */
        else begin
          normal_retire=1;
          check(!trace_o.trap,"successful instruction cannot trap");
          /* only explicitly modeled operations may contribute architectural progress. */
          case (expected.operation)
            NOP: begin end
            /* upper immediates write their independently declared value. */
            LUI: begin result_value=expected.immediate; write_rd=expected.rd!=0; end
            /* arithmetic uses the independently tracked older register value. */
            ADDI: begin
              check(defined_ref[expected.rs1],"initialized ADDI source");
              result_value=regs_ref[expected.rs1]+expected.immediate; write_rd=expected.rd!=0;
            end
            /* successful RAM data appear only at the ordered load retirement. */
            LOAD: begin
              check(defined_ref[expected.rs1] && regs_ref[expected.rs1]==32'h20000000,"load source and region");
              result_value=32'hcafebabe; write_rd=expected.rd!=0;
            end
            /* zero divided by zero has the specified all-ones quotient. */
            DIVIDE: begin result_value=32'hffffffff; write_rd=expected.rd!=0; end
            FENCE: begin end
            FENCEI: check(redirect_valid_o && redirect_pc_o==next_pc,"FENCE.I ordered restart");
            WFI: begin end
            /* return restores the interrupt stack and the recorded boundary PC. */
            MRET: begin
              next_pc=epc_ref; status_ref=32'h1880|(status_ref[7]?32'h8:0);
              check(redirect_valid_o && redirect_pc_o==next_pc,"MRET continuation");
            end
            /* CSR read/write suppression follows encoded indices, not source values. */
            CSR: begin
              check(expected.form inside {1,2,3,5,6,7},"modeled CSR form");
              csr_read=expected.form%4!=1 || expected.rd!=0;
              csr_write=expected.form%4==1 || expected.rs1!=0;
              source_value=expected.form>=5?32'(expected.rs1):regs_ref[expected.rs1];
              check(expected.form>=5 || defined_ref[expected.rs1],"initialized CSR source");
              old_csr=csr_value(expected.address);
              /* reads observe the pre-increment value at the retirement edge. */
              case (expected.form%4)
                1:new_csr=source_value;
                2:new_csr=old_csr|source_value;
                3:new_csr=old_csr&~source_value;
                default:new_csr=old_csr;
              endcase
              /* WARL masking is independent of the DUT's preview value. */
              if (expected.address==12'h320) new_csr&=5;
              if (expected.address==12'h300) new_csr=(new_csr&32'h88)|32'h1800;
              if (expected.address==12'h304) new_csr&=32'h888;
              if (expected.address==12'h305) new_csr&=32'hfffffffc;
              if (expected.address==12'h341) new_csr&=C_ENABLED?32'hfffffffe:32'hfffffffc;
              result_value=csr_read?old_csr:0; write_rd=expected.rd!=0;
              check(trace_o.csr_read==csr_read && trace_o.csr_write==csr_write &&
                  trace_o.csr_old==(csr_read?old_csr:0) && trace_o.csr_new==(csr_write?new_csr:0),
                  "retirement-time CSR access record");
              all_forms|=1<<expected.form;
              /* each independently addressed counter half must appear in coverage. */
              if (expected.address inside {12'hb00,12'hb80,12'hb02,12'hb82}) begin
                counter_reads+=int'(csr_read); counter_writes+=int'(csr_write);
                half_accesses|=expected.address==12'hb00 ? 1 : expected.address==12'hb80 ? 2 : expected.address==12'hb02 ? 4 : 8;
                suppressed_writes+=int'(!csr_write);
                retained_zero_writes+=int'(csr_write && expected.form%4!=1 && expected.rs1!=0 && source_value==0);
              end
            end
            default:check(0,"modeled instruction class");
          endcase
          check(trace_o.rd_write==write_rd && (!write_rd || (trace_o.rd==5'(expected.rd) && trace_o.value==result_value)),
              "architectural result including counter reads");
          /* reference GPRs change only after their instruction retires successfully. */
          if (write_rd) begin regs_ref[expected.rd]=result_value; defined_ref[expected.rd]=1; end
          retired++; compressed+=int'(expected.length==2);
        end
        check(trace_o.next_pc==next_pc,"architectural continuation");
        arch_pc=next_pc; live[id]=0; next_order++;
      end
      /* automatic instret increment depends on actual successful architectural disposition. */
      if (normal_retire && !inhibit_ref[2]) next_instret=instret_ref+1;
      /* explicit counter-half writes override the entire same-counter automatic increment. */
      if (trace_o.valid && !trace_o.trap && csr_write) begin
        case (expected.address)
          12'hb00:next_cycle={cycle_ref[63:32],new_csr};
          12'hb80:next_cycle={new_csr,cycle_ref[31:0]};
          12'hb02:next_instret={instret_ref[63:32],new_csr};
          12'hb82:next_instret={new_csr,instret_ref[31:0]};
          /* the new inhibit mask takes effect after the current edge. */
          12'h320:begin next_inhibit=new_csr; inhibit_writes++; end
          12'h300:status_ref=new_csr;
          12'h304:enable_ref=new_csr;
          12'h305:vector_ref=new_csr;
          12'h341:epc_ref=new_csr;
          default:check(0,"modeled CSR write address");
        endcase
      end
      /* interrupts save the current boundary without inventing a retired instruction. */
      if (irq_valid_o) begin
        check(irq_case && !trace_o.valid && status_ref[3] && enable_ref[11] && manual_levels[11] &&
            irq_pc_o==arch_pc && irq_cause_o==32'h8000000b && mepc_o==arch_pc,
            "interrupt boundary has no ordinary retirement");
        epc_ref=arch_pc; arch_pc=vector_ref; status_ref='h1880; irq_entries++;
      end
      /* count only automatic low-half carries and complete modulo wraps, not software writes. */
      if (next_cycle==cycle_ref+1 && cycle_ref[31:0]==32'hffffffff) cycle_rollovers++;
      if (next_instret==instret_ref+1 && instret_ref[31:0]==32'hffffffff) instret_rollovers++;
      if (next_cycle==0 && cycle_ref==64'hffffffffffffffff) cycle_wraps++;
      if (next_instret==0 && instret_ref==64'hffffffffffffffff) instret_wraps++;
      cycle_ref=next_cycle; instret_ref=next_instret; inhibit_ref=next_inhibit;
      /* actual stage ownership must equal the independent live instruction ledger. */
      for (int uid=0;uid<next_uid;uid++) begin
        owners=0;
        /* stalled tokens retain the same unique owner until transfer or disposition. */
        for (int stage=0;stage<5;stage++) owners+=int'(stage_valid_o[stage] && stage_token_o[stage].uid==64'(uid));
        check(owners==int'(live[uid]),"instruction conservation");
      end
    end
    /* responder deassertion settles before serializing combinational observation fields. */
    #1;
    actual_cycle=mcycle_o; actual_instret=minstret_o;
    /* mutate observed values to prove the edge ledger detects incorrect increments. */
    if ($test$plusargs("mutate_cycle") && !cold_reset_i && !inhibit_ref[0] && !mutation_applied) begin
      actual_cycle++; mutation_applied=1;
    end
    /* a compressed instruction must never count as two ordinary retirements. */
    if ($test$plusargs("mutate_compressed") && trace_o.valid && !trace_o.trap && trace_o.packet.length==2 && !mutation_applied) begin
      actual_instret++; mutation_applied=1;
    end
    /* a terminal exception is deliberately corrupted only in this detector calibration. */
    if ($test$plusargs("mutate_trap") && trace_o.valid && trace_o.trap && !mutation_applied) begin
      actual_instret++; mutation_applied=1;
    end
    check(actual_cycle==cycle_ref,"cycle counter agrees with independent clock ledger");
    check(actual_instret==instret_ref,"retired counter agrees with independent execution ledger");
    check(mcountinhibit_o==inhibit_ref,"inhibit state agrees with architectural writes");
    /* capture rearm begins one explicit new observer session at the initial isolated reset. */
    if (capture_reset_i) begin
      check(!observation.valid && observation.overflow==0,"observer rearm does not invent an edge");
      observer_sequence=0; observer_epoch=0; observer_retired=0;
    end
    /* every following clock preserves complete before/after records, including reset episodes. */
    else begin
      observer_sequence++;
      if (cold_reset_i && !observer_previous_reset) observer_epoch++;
      if (trace_o.valid && !trace_o.trap) observer_retired++;
      check(observation.valid && observation.overflow==0 && observation.sequence_id==observer_sequence &&
          observation.epoch==observer_epoch,"observer sequence and reset epoch");
      check(observation.retired_before==pre_total_retired && observation.retired_after==observer_retired,
          "observer retirement total ignores architectural counter writes");
      check(observation.cycle_before==pre_cycle && observation.instret_before==pre_instret &&
          observation.inhibit_before==pre_inhibit && observation.cycle_after==cycle_ref &&
          observation.instret_after==instret_ref && observation.inhibit_after==inhibit_ref,
          "observer counter edge pairing");
      check(observation.cold_reset==cold_reset_i && !observation.hart_reset && observation.isolated &&
          !observation.debug_mode && !observation.debug_ebreak_entry && observation.hold==pre_holds &&
          observation.stages_before==pre_stages && observation.stages_after==stage_valid_o &&
          observation.transfers==pre_transfers && observation.input_accept==input_fire &&
          observation.input_packet==offered,"observer pipeline and reset record");
      check(observation.terminal==trace_o && observation.kill_valid==kill_valid_o && observation.irq==irq_valid_o &&
          observation.irq_pc==irq_pc_o && observation.irq_cause==irq_cause_o && observation.idle==idle_o &&
          observation.fatal==fatal_o && observation.fatal_record==fatal_record_o &&
          observation.i_fatal==fetch_fatal && observation.i_fatal_reason==fetch_reason &&
          observation.redirect==redirect_valid_o && observation.redirect_pc==redirect_pc_o,
          "observer settled architectural events");
      check(observation.i_offer==pre_i_valid && observation.i_accept==i_accept && observation.i_response==i_reply &&
          observation.i_drop==pre_drop && observation.i_addr==pre_i_address && observation.i_tag==pre_i_tag &&
          observation.i_parcels==pre_i_parcels && observation.d_offer==pre_d_valid && observation.d_accept==d_accept &&
          observation.d_response==d_reply && observation.d_addr==pre_d_address && observation.d_tag==pre_d_tag,
          "observer physical request events");
      /* every packed stage identity is reconstructible without consulting private core storage. */
      for (int stage=0;stage<5;stage++) begin
        check(observation.kill_uid[64*stage+:64]==kill_uid_o[stage] &&
            observation.stage_uid[64*stage+:64]==stage_token_o[stage].uid,"observer identity lanes");
      end
    end
    observer_previous_reset=cold_reset_i;
    /* the packed payload preserves every schema field alongside readable clock and retirement context. */
    if (trace_fd!=0) $fdisplay(trace_fd,
        "{\"edge\":%0d,\"case\":%0d,\"valid\":%0d,\"sequence\":%0d,\"epoch\":%0d,\"retired_before\":%0d,\"retired_after\":%0d,\"cycle_before\":\"%016x\",\"cycle_after\":\"%016x\",\"instret_before\":\"%016x\",\"instret_after\":\"%016x\",\"terminal\":%0d,\"trap\":%0d,\"pc\":\"%08x\",\"raw\":\"%08x\",\"packed\":\"%0h\"}",
        edges,cases,observation.valid,observation.sequence_id,observation.epoch,observation.retired_before,
        observation.retired_after,observation.cycle_before,observation.cycle_after,observation.instret_before,
        observation.instret_after,trace_o.valid,trace_o.trap,trace_o.packet.pc,trace_o.packet.raw,observation);
  end

  /* advance clocks only after stimulus and previous observation records have settled. */
  task automatic tick;
    #2; clk_i=1; #3; clk_i=0;
  endtask

  /* begin each image in a fresh isolated epoch with only x0 defined. */
  task automatic begin_case;
    cases++; run_enable=0; hold_i=0; manual_levels=0; irq_case=0; wake_ticks=0;
    terminal=0; builder_pc=0; case_edges=0;
    /* reserved image gaps make an unintended instruction path observable. */
    for (int n=0;n<WORDS;n++) begin image[n]=0; program_ref[n]='0; end
    cold_reset_i=1; tick(); capture_reset_i=0; cold_reset_i=0; tick(); tick();
  endtask

  /* execute the fixed corpus under independently seeded service and stage backpressure. */
  task automatic execute;
    run_enable=1;
    /* bounded progress prevents a missing retirement from silently passing. */
    while (!terminal && case_edges<12000) begin
      /* every stage can stall without stopping either target or counter clock. */
      for (int stage=0;stage<5;stage++) hold_i[stage]=(random_word()%8)==0;
      /* WFI remains idle for twelve clocks before the persistent external event arrives. */
      if (irq_case && idle_o) begin wake_ticks++; if (wake_ticks>=12) manual_levels='h800; end
      tick();
    end
    check(terminal,"program termination deadline"); run_enable=0; hold_i=0;
    repeat (140) tick();
    check(!i_owned && !d_owned && !fetch_busy && !mem_busy_o,"all physical requests drain");
    /* every program ends in a trapping disposition that kills speculative younger tokens. */
    for (int uid=0;uid<next_uid;uid++) check(!live[uid],"terminal instruction conservation");
  endtask

  /* all six forms exercise each low/high counter half while increments are enabled. */
  task automatic access_matrix(input logic [31:0] inhibit);
    logic [11:0] address;
    begin_case(); set_csr(12'h320,inhibit); load_constant(5,0); load_constant(6,32'h01020304);
    /* source-index zero suppresses set/clear writes; nonzero zero-valued x5 still writes. */
    for (int half=0;half<4;half++) begin
      address=half==0?12'hb00:half==1?12'hb80:half==2?12'hb02:12'hb82;
      /* every legal form uses both destination suppression and explicit reads. */
      for (int form=1;form<8;form++) begin
        /* funct3 four is reserved and excluded from the legal six-form matrix. */
        if (form!=4) begin
          emit_csr(address,form,10,0);
          emit_csr(address,form,0,5);
          emit_csr(address,form,11,form>=5?7:6);
        end
      end
      emit_csr(address,2,12,5); emit_csr(address,3,13,5);
    end
    finish_program(); execute();
  endtask

  /* writes near each boundary establish genuine automatic low carries and full wraps. */
  task automatic rollover_case(input bit full_wrap);
    begin_case();
    set_csr(12'hb80,full_wrap?32'hffffffff:32'h12345678); set_csr(12'hb00,32'hffffffff);
    set_csr(12'hb82,full_wrap?32'hffffffff:32'h87654321); set_csr(12'hb02,32'hffffffff);
    emit_csr(12'h320,5,0,0);
    emit(32'h00000013,4,NOP,0,0);
    /* a compressed instruction contributes one instret increment and may straddle the next wide CSR. */
    if (C_ENABLED) begin emit(32'h00000001,2,NOP,0,0); emit(32'h00004481,2,ADDI,9,0,0); end
    emit_csr(12'hb80,2,10,0); emit_csr(12'hb00,2,11,0); emit_csr(12'hb80,2,12,0);
    emit_csr(12'hb82,2,13,0); emit_csr(12'hb02,2,14,0); emit_csr(12'hb82,2,15,0);
    set_csr(12'h320,5); finish_program(11); execute();
  endtask

  /* stalls, fences, division and terminal exceptions share the same independent retirement ledger. */
  task automatic execution_case(input int ending);
    begin_case(); emit_csr(12'h320,5,0,0); load_constant(20,32'h20000000);
    emit(encode_i('h03,7,20,2,0),4,LOAD,7,20);
    emit(32'h020042b3,4,DIVIDE,5,0);
    emit(32'h0ff0000f,4,FENCE,0,0); emit(32'h0000100f,4,FENCEI,0,0);
    /* compact HINT and arithmetic retire once each despite different encoded lengths. */
    if (C_ENABLED) begin
      emit(32'h00000001,2,NOP,0,0); emit(32'h00004481,2,ADDI,9,0,0); emit(32'h00000485,2,ADDI,9,9,1);
    end
    emit_csr(12'hb00,2,10,0); emit_csr(12'hb02,2,11,0);
    /* illegal encodings and memory alignment faults retain precise architectural ordering. */
    if (ending==2) begin
      emit(32'h0000000b,4,TRAP,0,0); program_ref[(builder_pc-4)/2].cause=2;
    end
    /* natural misalignment faults locally without a target effect. */
    else if (ending==3) begin
      load_constant(20,32'h20000001); emit(encode_i('h03,0,20,2,0),4,TRAP,0,20);
      program_ref[(builder_pc-4)/2].cause=4; program_ref[(builder_pc-4)/2].tval=32'h20000001;
    end
    else finish_program(ending==1?11:3,C_ENABLED && ending==4);
    execute();
  endtask

  /* unsupported user aliases trap even when a CSR instruction suppresses its write. */
  task automatic absent_alias(input logic [11:0] address);
    int index;
    begin_case(); emit_csr(12'h320,5,0,0); index=builder_pc/2; check(index>=0 && index<WORDS,"bounded alias location"); emit_csr(address,2,10,0);
    program_ref[index].operation=TRAP; program_ref[index].cause=2; execute();
  endtask

  /* WFI clocks keep mcycle active and IRQ/MRET boundaries contribute no phantom retirement. */
  task automatic interrupt_program;
    int continuation;
    begin_case(); irq_case=1; set_csr(12'h305,32'h100); set_csr(12'h304,32'h800); set_csr(12'h300,8);
    emit_csr(12'h320,5,0,0); emit(32'h10500073,4,WFI,0,0); continuation=builder_pc;
    emit_csr(12'hb00,2,10,0); emit_csr(12'hb02,2,11,0); finish_program();
    builder_pc='h100; emit_csr(12'h304,5,0,0); emit_csr(12'h341,2,12,0); emit(32'h30200073,4,MRET,0,0);
    execute(); check(irq_entries>0 && wake_ticks>=12 && regs_ref[12]==32'(continuation),"WFI interrupt and return coverage");
  endtask

  /* directed programs remain identical across seeds while timing and occupancy vary. */
  initial begin
    /* initialize the failure ring before the first reset-qualified edge. */
    for (int n=0;n<32;n++) begin history_pc[n]=0; history_cycle[n]=0; history_instret[n]=0; history_stages[n]=0; end
    if (!$value$plusargs("seed=%d",seed)) seed=1;
    rng=32'(seed);
    /* host traces are optional and never apply backpressure to the CPU. */
    if ($value$plusargs("trace_file=%s",trace_path)) begin
      trace_fd=$fopen(trace_path,"w"); check(trace_fd!=0,"trace output opened");
      $fdisplay(trace_fd,"{\"schema\":\"DRG5-OBS1\",\"packed_bits\":%0d,\"C\":%0d,\"diagnostic\":%0d,\"forwarding\":%0d,\"seed\":%0d}",
          $bits(observe_t),C_ENABLED,DIAGNOSTIC,FORWARDING,seed);
    end
    access_matrix(0); access_matrix(1); access_matrix(4); access_matrix(5);
    rollover_case(0); rollover_case(1);
    /* each terminal exception is independently exercised after ordinary counted execution. */
    for (int ending=0;ending<5;ending++) execution_case(ending);
    absent_alias(12'hc00); absent_alias(12'hc80); absent_alias(12'hc02); absent_alias(12'hc82);
    absent_alias(12'hc01); absent_alias(12'hc81); interrupt_program();
    check(all_forms==238 && half_accesses==15 && suppressed_writes>0 && retained_zero_writes>0,
        "all CSR forms halves and suppression distinctions exercised");
    check(cycle_rollovers>=2 && instret_rollovers>=2 && cycle_wraps>=1 && instret_wraps>=1,
        "genuine counter rollover and modulo-wrap coverage");
    check(irq_entries==1 && idle_edges>=12 && divide_waits>0 && d_accepts==5,
        "stalls WFI interrupt division and load coverage");
    check(!C_ENABLED || compressed>0,"compressed instruction retirement coverage");
    check(i_offers==i_accepts && i_accepts==i_responses && d_offers==d_accepts && d_accepts==d_responses,
        "every bus offer has exactly one acceptance and response");
    $display("COUNTER_EXEC_PASS C=%0d diagnostic=%0d forwarding=%0d seed=%0d cases=%0d edges=%0d checks=%0d retired=%0d traps=%0d compressed=%0d IRQ=%0d idle=%0d csr_reads=%0d csr_writes=%0d inhibit_writes=%0d suppressed=%0d zero_index_writes=%0d cycle_rollovers=%0d instret_rollovers=%0d cycle_wraps=%0d instret_wraps=%0d holds=%0d divide_waits=%0d I=%0d D=%0d program_digest=%016x",
        C_ENABLED,DIAGNOSTIC,FORWARDING,seed,cases,edges,checks,retired,trapped,compressed,irq_entries,idle_edges,
        counter_reads,counter_writes,inhibit_writes,suppressed_writes,retained_zero_writes,cycle_rollovers,
        instret_rollovers,cycle_wraps,instret_wraps,held_edges,divide_waits,i_responses,d_responses,program_digest);
    /* the mandatory footer distinguishes a complete capture from a truncated host file. */
    if (trace_fd!=0) begin
      $fdisplay(trace_fd,"{\"end\":true,\"edges\":%0d,\"sequence\":%0d,\"epoch\":%0d,\"retired\":%0d}",
          edges,observer_sequence,observer_epoch,observer_retired);
      $fclose(trace_fd);
    end
    $finish;
  end
endmodule
