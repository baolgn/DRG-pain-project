/* compare fetched mixed-width programs with independent instruction semantics. */
module drg5_compressed_execution_tb #(
  parameter bit C_ENABLED = 1, M_ENABLED = 1, DIAGNOSTIC = 0, FORWARDING = 1
);
  import drg5_control_pkg::*;
  localparam int CAPACITY = 512, WORDS = 4096;
  localparam int NOP=0, ADDI=1, LUI=2, ADD=3, SUB=4, XOR_OP=5, OR_OP=6, AND_OP=7,
      SLL=8, SRL=9, SRA=10, ANDI=11, LOAD=12, STORE=13, JUMP=14, JREG=15,
      BEQ=16, BNE=17, TRAP=18, MISA=19, MUL_OP=20, EPC_READ=21, EPC_WRITE=22,
      VECTOR_WRITE=23, RETURN=24, MIE_WRITE=25, STATUS_WRITE=26, WAIT_IRQ=27, DIV_OP=28;
  /* original program metadata supplies semantics independently of RTL decompression. */
  typedef struct packed {
    logic present;
    logic [31:0] raw;
    logic [3:0] raw_valid;
    logic [2:0] length;
    int operation, rd, rs1, rs2;
    logic [31:0] imm, cause, tval;
  } instruction_t;
  instruction_t program_ref [0:WORDS-1];
  logic [15:0] image [0:WORDS-1];
  bit image_fault [0:WORDS-1];
  logic [31:0] regs_ref [0:31], physical_ram [0:255], architectural_ram [0:255];
  bit defined_ref [0:31];
  packet_t originals [0:CAPACITY-1];
  bit live [0:CAPACITY-1];
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
      flush_ready_o, flush_aborted_o, irq_pc_o, irq_cause_o};
  logic frontend_valid;
  assign in_valid_i = frontend_valid && run_enable;
  assign frontend_ready = in_ready_o && run_enable;

  /* use the production fetch/packet adapter with a finite stress deadline. */
  drg5_frontend #(.C_ENABLED(C_ENABLED), .GEN_BITS(2), .MAX_WAIT_CYCLES(64), .TEST_REGIONS(1)) frontend (
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
      .FORWARDING(FORWARDING), .IRQ_ENABLED(1), .TEST_REGIONS(1), .D_MAX_WAIT_CYCLES(64)) dut (
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

  bit i_owned=0, i_accepted=0, i_stale=0, d_owned=0, d_accepted=0;
  logic [31:0] i_address=0, i_tag=0, i_data=0, d_address=0, d_tag=0, d_data=0, d_reply=0;
  logic [1:0] i_parcels=0, i_fault=0, d_status=0;
  bit d_write=0;
  int i_age=0, i_response_age=0, i_accept_delay=0, i_response_delay=1;
  int d_age=0, d_response_age=0, d_accept_delay=0, d_response_delay=1;
  int acceptance_limit=4, response_limit=6, d_accept_setting=2, d_response_setting=3;
  int targeted_mode=0;
  logic [31:0] targeted_address=0, d_fault_address='1;
  int seed=1, rng=1, program_rng=1, cases=0, edges=0, checks=0, retired=0, traps=0, killed=0;
  int i_offers=0, i_accepts=0, i_replies=0, stale_replies=0, d_offers=0, d_accepts=0, d_replies=0;
  int reads=0, writes=0, mmio_effects=0, mmio_ref=0, case_reads=0, case_writes=0;
  int retired_reads=0, retired_writes=0, held_edges=0, compressed_retired=0, straddled_retired=0;
  int first_faults=0, second_faults=0, hints=0, links=0, branches=0, max_i_wait=0, max_d_wait=0;
  int next_uid=0, next_order=0, builder_pc=0, case_steps=0;
  logic [31:0] arch_pc=0, vector_ref=0, epc_ref=0, enable_ref=0;
  bit global_enable=0, wake_on_idle=0;
  int interrupts=0, idle_edges=0, pending_edges=0;
  bit terminal=0, random_holds=0, force_branch_hold=0, mutation_applied=0, fixed_service=0, grid_holds=0;
  int simultaneous_discard=0, late_c_wait=0;
  logic [63:0] program_digest=64'hcbf29ce484222325, retirement_digest=64'hcbf29ce484222325, effect_digest=64'hcbf29ce484222325;
  logic [4:0] observed_holds=0;
  logic [31:0] history_pc [0:31], history_raw [0:31];
  logic [4:0] history_valid [0:31];

  /* a local LCG fixes every randomized service and instruction choice. */
  function automatic int unsigned random_word;
    rng = int'(32'(rng) * 32'd1664525 + 32'd1013904223);
    return unsigned'(rng);
  endfunction

  /* program data have a separate seed stream so execution timing cannot change the test image. */
  function automatic int unsigned program_random_word;
    program_rng=int'(32'(program_rng)*32'd1664525+32'd1013904223);
    return unsigned'(program_rng);
  endfunction

  /* every failed check prints recent original instruction and owner state. */
  task automatic check(input bit condition, input string label_text);
    checks++;
    /* the exact named comparator must fire for each detector calibration. */
    if (!condition) begin
      $display("C_EXEC_FAILURE label=%s seed=%0d case=%0d edge=%0d arch_pc=%08x I=%b/%b/%08x D=%b/%b/%08x",
          label_text, seed, cases, edges, arch_pc, i_owned, i_accepted, i_address, d_owned, d_accepted, d_address);
      /* the ring preserves enough instruction context to reproduce the first divergence. */
      for (int n=0; n<32; n++) $display("C_HISTORY age=%0d pc=%08x raw=%08x stages=%b", n,
          history_pc[(edges+n)%32], history_raw[(edges+n)%32], history_valid[(edges+n)%32]);
      $fatal(1, "C_EXEC_CHECK_FAILED %s", label_text);
    end
  endtask

  /* map safe executable overlays to disjoint fixture storage without peripheral aliases. */
  function automatic int image_index(input logic [31:0] unused_address);
    return unused_address[31:16] == 16'h6000 ? 3072 + int'(unused_address[10:1]) : int'(unused_address[12:1]);
  endfunction

  /* target ready and response signals depend only on retained target ownership. */
  always_comb begin
    i_req_ready_i = i_owned && !i_accepted && i_age >= i_accept_delay && !cold_reset_i;
    i_rsp_valid_i = i_owned && i_accepted && i_response_age >= i_response_delay && !cold_reset_i;
    /* the directed coincidence case presents its retained error on the redirect edge. */
    if (targeted_mode==3 && i_address==targeted_address)
      i_rsp_valid_i=i_owned && i_accepted && redirect_valid_o && !cold_reset_i;
    i_rsp_tag_i = i_tag; i_rsp_data_i = i_data; i_rsp_parcels_i = i_parcels;
    i_rsp_fault_i = i_fault; i_rsp_status_i = 0;
    d_req_ready_i = d_owned && !d_accepted && d_age >= d_accept_delay && !cold_reset_i;
    d_rsp_valid_i = d_owned && d_accepted && d_response_age >= d_response_delay && !cold_reset_i;
    d_rsp_tag_i = d_tag; d_rsp_rdata_i = d_status != 0 || d_write ? 0 : d_reply; d_rsp_status_i = d_status;
  end

  /* construct standard 32-bit encodings independently of production decoder helpers. */
  function automatic logic [31:0] enc_i(input int unused_opcode, unused_rd, unused_rs1, unused_funct3, input logic [31:0] unused_imm);
    return {unused_imm[11:0],5'(unused_rs1),3'(unused_funct3),5'(unused_rd),7'(unused_opcode)};
  endfunction
  /* direct J-field placement gives the independent program builder its target. */
  function automatic logic [31:0] enc_j(input int unused_rd, input logic [31:0] unused_imm);
    return {unused_imm[20],unused_imm[10:1],unused_imm[11],unused_imm[19:12],5'(unused_rd),7'h6f};
  endfunction
  /* direct C-format placement is checked separately by exhaustive classification tests. */
  function automatic logic [15:0] enc_c(input int kind, rd, rs1, rs2, input logic [31:0] unused_imm);
    /* each format uses architectural operands, never an expanded DUT instruction. */
    case (kind)
      0: return {3'b000,unused_imm[5:4],unused_imm[9:6],unused_imm[2],unused_imm[3],3'(rd-8),2'b00};
      1: return {3'b010,unused_imm[5:3],3'(rs1-8),unused_imm[2],unused_imm[6],3'(rd-8),2'b00};
      2: return {3'b110,unused_imm[5:3],3'(rs1-8),unused_imm[2],unused_imm[6],3'(rs2-8),2'b00};
      3,5: return {3'(kind==3?0:2),unused_imm[5],5'(rd),unused_imm[4:0],2'b01};
      4,15: return {3'(kind==4?1:5),unused_imm[11],unused_imm[4],unused_imm[9:8],unused_imm[10],unused_imm[6],unused_imm[7],unused_imm[3:1],unused_imm[5],2'b01};
      6: return {3'b011,unused_imm[9],5'd2,unused_imm[4],unused_imm[6],unused_imm[8:7],unused_imm[5],2'b01};
      7: return {3'b011,unused_imm[17],5'(rd),unused_imm[16:12],2'b01};
      8,9,10: return {3'b100,unused_imm[5],2'(kind-8),3'(rd-8),unused_imm[4:0],2'b01};
      11,12,13,14: return {3'b100,1'b0,2'b11,3'(rd-8),2'(kind-11),3'(rs2-8),2'b01};
      16,17: return {3'(kind==16?6:7),unused_imm[8],unused_imm[4:3],3'(rs1-8),unused_imm[7:6],unused_imm[2:1],unused_imm[5],2'b01};
      18: return {3'b000,unused_imm[5],5'(rd),unused_imm[4:0],2'b10};
      19: return {3'b010,unused_imm[5],5'(rd),unused_imm[4:2],unused_imm[7:6],2'b10};
      20,21: return {4'b1000,5'(rd),5'(rs2),2'b10};
      22,23,24: return {4'b1001,5'(rd),5'(rs2),2'b10};
      25: return {3'b110,unused_imm[5:2],unused_imm[7:6],5'(rs2),2'b10};
      default: return 0;
    endcase
  endfunction

  /* pair each emitted raw encoding with independently supplied architectural semantics. */
  task automatic emit(input logic [31:0] raw, input int length, operation, rd, rs1, rs2,
      input logic [31:0] imm);
    int unused_index;
    unused_index=image_index(32'(builder_pc));
    program_ref[unused_index]='{present:1,raw:raw,raw_valid:4'(length==2?3:15),length:3'(length),
        operation:operation,rd:rd,rs1:rs1,rs2:rs2,imm:imm,cause:0,tval:0};
    image[unused_index]=raw[15:0];
    /* wide encodings retain their high parcel even across a fetched-word boundary. */
    if (length==4) image[image_index(32'(builder_pc)+2)]=raw[31:16];
    program_digest=(program_digest^{32'(builder_pc),raw})*64'h100000001b3;
    builder_pc+=length;
  endtask

  /* select the independent instruction meaning while reusing only encoding construction. */
  task automatic emit_c(input int kind, rd, rs1, rs2, input logic [31:0] imm);
    int operation, destination, source;
    operation=NOP; destination=rd; source=rs1;
    /* semantics are selected from the requested operation, not decoded from the encoded word. */
    case (kind)
      /* add the compact stack offset. */
      0: begin operation=ADDI; source=2; end
      /* select the compact load base. */
      1,19: begin operation=LOAD; source=kind==19?2:rs1; end
      /* select the compact store base. */
      2,25: begin operation=STORE; source=kind==25?2:rs1; end
      /* select the immediate arithmetic source. */
      3,6: begin operation=ADDI; source=kind==6?2:rd; end
      /* select the jump link destination. */
      4,15: begin operation=JUMP; destination=kind==4?1:0; end
      /* load a signed immediate. */
      5: begin operation=ADDI; source=0; end
      7: operation=LUI;
      /* select logical right shift. */
      8: begin operation=SRL; source=rd; end
      /* select arithmetic right shift. */
      9: begin operation=SRA; source=rd; end
      /* select immediate bitwise AND. */
      10: begin operation=ANDI; source=rd; end
      /* select subtraction. */
      11: begin operation=SUB; source=rd; end
      /* select bitwise XOR. */
      12: begin operation=XOR_OP; source=rd; end
      /* select bitwise OR. */
      13: begin operation=OR_OP; source=rd; end
      /* select bitwise AND. */
      14: begin operation=AND_OP; source=rd; end
      16: operation=BEQ;
      17: operation=BNE;
      /* select logical left shift. */
      18: begin operation=SLL; source=rd; end
      /* read the old jump-register source. */
      20,23: begin operation=JREG; source=rd; destination=kind==23?1:0; end
      /* move the second source. */
      21: begin operation=ADD; source=0; end
      /* add both register sources. */
      24: begin operation=ADD; source=rd; end
      22: operation=TRAP;
      default: operation=NOP;
    endcase
    emit({16'b0,enc_c(kind,rd,rs1,rs2,imm)},2,operation,destination,source,rs2,imm);
    /* C.EBREAK remains a synchronous exception, including its original two-byte identity. */
    if (kind==22) begin
      program_ref[image_index(32'(builder_pc-2))].cause=3;
      program_ref[image_index(32'(builder_pc-2))].tval=32'(builder_pc-2);
    end
  endtask

  /* an explicit terminal prevents speculative zeros from selecting the case outcome. */
  task automatic finish_program;
    emit(32'h00100073,4,TRAP,0,0,0,0);
    program_ref[image_index(32'(builder_pc-4))].cause=3;
    program_ref[image_index(32'(builder_pc-4))].tval=32'(builder_pc-4);
  endtask

  /* keep the stack and compact memory base defined while other operands start from encoded writes. */
  task automatic initialize_program;
    /* initialization deliberately writes every readable register instead of assuming reset zeros. */
    for (int r=1;r<32;r++) emit(enc_i('h13,r,0,0,32'(r*7)),4,ADDI,r,0,0,32'(r*7));
    emit(32'h20000137,4,LUI,2,0,0,32'h20000000);
    emit(enc_i('h13,2,2,0,'h100),4,ADDI,2,2,0,'h100);
    emit(32'h20000437,4,LUI,8,0,0,32'h20000000);
  endtask

  /* one scoreboard samples old handshakes and then checks registered ownership changes. */
  initial forever begin : scoreboard
    bit input_fire, i_accept_fire, i_complete_fire, d_accept_fire, d_complete_fire, pre_redirect;
    bit pre_i_request, pre_d_request, pre_i_drop, pre_fatal, pre_idle, pre_pending;
    logic [31:0] pre_i_addr, pre_i_tag, pre_d_addr, pre_d_tag, pre_d_data;
    logic [1:0] pre_i_parcels;
    bit pre_d_write;
    packet_t accepted_packet;
    token_t previous [0:4];
    logic [4:0] previous_valid;
    instruction_t expected;
    logic [31:0] value, next_pc, address, lhs, rhs, observed_raw, observed_epc, observed_value;
    bit write_reg, taken;
    int unused_index, id, count;
    @(posedge clk_i);
    input_fire=in_valid_i && in_ready_o; accepted_packet=in_packet_i;
    i_accept_fire=i_req_valid_o && i_req_ready_i; i_complete_fire=i_rsp_valid_i && i_rsp_ready_o;
    d_accept_fire=d_req_valid_o && d_req_ready_i; d_complete_fire=d_rsp_valid_i && d_rsp_ready_o;
    pre_i_request=i_req_valid_o; pre_i_addr=i_req_addr_o; pre_i_tag=i_req_tag_o;
    pre_i_parcels=i_req_parcels_o; pre_i_drop=fetch_drop; pre_redirect=redirect_valid_o;
    pre_d_request=d_req_valid_o; pre_d_addr=d_req_addr_o; pre_d_tag=d_req_tag_o;
    pre_d_data=d_req_wdata_o; pre_d_write=d_req_write_o;
    previous=stage_token_o; previous_valid=stage_valid_o;
    pre_fatal=fetch_fatal || fetch_reason!=0 || fatal_o || fatal_record_o.valid;
    pre_idle=idle_o; pre_pending=entry_pending_o;
    /* observe actual handshake outputs independently of responder state updates. */
    if (!cold_reset_i) begin
      check(fetch_accept==i_accept_fire && fetch_complete==i_complete_fire,"I handshake observation");
      check(!fetch_launch || (!pre_redirect && !pre_pending),"redirect or asynchronous entry blocks new I launch");
    end
    #1;
    edges++; case_steps++;
    history_pc[edges%32]=in_packet_i.pc; history_raw[edges%32]=in_packet_i.raw;
    history_valid[edges%32]=stage_valid_o;
    /* isolated reset destroys both fixture and CPU epochs before identity reuse. */
    if (cold_reset_i) begin
      i_owned=0; i_accepted=0; i_stale=0; d_owned=0; d_accepted=0;
      next_uid=0; next_order=0; arch_pc=0; vector_ref=0; epc_ref=0; enable_ref=0; global_enable=0; terminal=0; mmio_ref=0; mmio_effects=0;
      case_reads=0; case_writes=0; retired_reads=0; retired_writes=0;
      /* architectural reset defines only x0; programs explicitly initialize every used register. */
      for (int r=0;r<32;r++) begin regs_ref[r]=0; defined_ref[r]=r==0; end
      /* no live identity or historical token may survive positive isolation. */
      for (int n=0;n<CAPACITY;n++) begin live[n]=0; originals[n]='0; end
    end
    /* all nonreset edges preserve one instruction owner and one bus owner. */
    else begin
      check(!pre_fatal,"unexpected fatal containment");
      check(wake_on_idle || (!irq_valid_o && !idle_o),"unexpected asynchronous event");
      idle_edges+=int'(pre_idle); pending_edges+=int'(pre_pending);
      /* an unfinished M producer must delay a younger compact consumer in the overlapping build. */
      if (previous_valid[2] && previous[2].md_decoded && !previous[2].md_done &&
          previous_valid[1] && previous[1].p.length==2) late_c_wait++;
      /* a stream redirect makes the target-side old response permanently stale. */
      if (pre_redirect && i_owned) i_stale=1;
      /* launched requests retain their descriptor through acceptance. */
      if (i_owned && !i_accepted) check(pre_i_request && pre_i_addr==i_address &&
          pre_i_tag==i_tag && pre_i_parcels==i_parcels,"stable unaccepted I request");
      /* accepted requests never launch a second physical access. */
      if (i_owned && i_accepted) check(!pre_i_request,"duplicate accepted I request");
      /* a late response is consumed once without restoring a revoked generation. */
      if (i_complete_fire) begin
        check(i_owned && i_accepted,"I response has exactly one owner");
        check(pre_i_drop==i_stale,"stale I response disposition");
        /* faulted stale parcels cannot leak into trap state. */
        if (i_stale) stale_replies++;
        /* count a genuinely simultaneous redirect and faulted response handshake. */
        if (pre_redirect && i_fault!=0) simultaneous_discard++;
        i_owned=0; i_accepted=0; i_replies++;
      end
      /* independently delayed acceptance samples instruction bytes exactly once. */
      else if (i_accept_fire) begin
        check(i_owned && !i_accepted,"I single acceptance");
        i_accepted=1; i_accepts++; i_response_age=0; i_data=0; i_fault=0;
        /* unused and faulted parcel lanes carry canonical zero data. */
        for (int parcel=0;parcel<2;parcel++) begin
          /* each requested halfword has independent access-error attribution. */
          if (i_parcels[parcel]) begin
            unused_index=image_index(i_address+32'(parcel*2));
            i_fault[parcel]=image_fault[unused_index];
            i_data[parcel*16+:16]=image_fault[unused_index]?16'b0:image[unused_index];
          end
        end
      end
      /* response latency advances only after acceptance. */
      else if (i_owned && i_accepted) i_response_age++;
      /* request acceptance latency advances independently from response timing. */
      else if (i_owned) begin
        i_age++; max_i_wait=i_age>max_i_wait?i_age:max_i_wait;
      end
      /* first request-valid creates the target's immutable descriptor. */
      else if (pre_i_request) begin
        check(pre_i_addr[1:0]==0 && pre_i_parcels!=0,"I aligned parcel descriptor");
        check(pre_i_addr<8192 || pre_i_addr inside {32'h60000000,32'h60000004,32'hfffffffc},"I peripheral region prohibited");
        i_owned=1; i_accepted=0; i_stale=pre_redirect; i_address=pre_i_addr;
        i_tag=pre_i_tag; i_parcels=pre_i_parcels; i_age=0; i_offers++;
        i_accept_delay=fixed_service?acceptance_limit:int'(random_word()%32'(acceptance_limit+1));
        i_response_delay=fixed_service?response_limit:1+int'(random_word()%32'(response_limit));
        /* held branches arrange redirects during both offered and accepted requests. */
        if (i_address==targeted_address && targeted_mode!=0) begin
          i_accept_delay=targeted_mode==1?18:0;
          i_response_delay=targeted_mode==2?18:1;
        end
      end
      /* data offers have independent stable ownership and full-word lane checks. */
      if (d_owned && !d_accepted) check(pre_d_request && pre_d_addr==d_address &&
          pre_d_tag==d_tag && pre_d_data==d_data && pre_d_write==d_write,"stable unaccepted D request");
      /* an accepted data descriptor cannot be offered for a second physical acceptance. */
      if (d_owned && d_accepted) check(!pre_d_request,"duplicate accepted D request");
      /* a completed response cannot authorize replay of the accepted physical effect. */
      if (d_complete_fire) begin
        check(d_owned && d_accepted,"D response has exactly one owner");
        d_owned=0; d_accepted=0; d_replies++;
      end
      /* physical reads and writes occur once at acceptance, independently from retirement. */
      else if (d_accept_fire) begin
        check(d_owned && !d_accepted,"D single acceptance");
        d_accepted=1; d_accepts++; d_response_age=0; d_reply=0;
        /* proven rejection causes no physical target effect. */
        if (d_status==0) begin
          /* the MMIO read counter exposes duplicate reads even when rd is x0. */
          if (d_address[31:12]==20'h40000) begin
            d_reply=32'(mmio_effects); mmio_effects++;
            /* an injected duplicate effect must reach the ordinary physical-effect comparator. */
            if ($test$plusargs("mutate_effect") && d_write && !mutation_applied) begin mmio_effects++; mutation_applied=1; end
          end
          /* ordinary RAM supplies independent stored values and write effects. */
          else if (d_write) physical_ram[d_address[9:2]]=d_data;
          /* reads sample memory only once at physical acceptance. */
          else d_reply=physical_ram[d_address[9:2]];
          effect_digest=(effect_digest^{d_address,d_write?d_data:d_reply})*64'h100000001b3;
          effect_digest=(effect_digest^{63'b0,d_write})*64'h100000001b3;
          /* separate read/write counts detect duplicate effects beyond retirement comparison. */
          if (d_write) begin writes++; case_writes++; end
          /* side-effectful reads are tracked as rigorously as writes. */
          else begin reads++; case_reads++; end
        end
      end
      /* the response timer cannot count time spent waiting for acceptance. */
      else if (d_owned && d_accepted) d_response_age++;
      /* an offered transaction remains exposed while the target stalls acceptance. */
      else if (d_owned) begin d_age++; max_d_wait=d_age>max_d_wait?d_age:max_d_wait; end
      /* first data request is checked against the oldest independent architectural instruction. */
      else if (pre_d_request) begin
        expected=program_ref[image_index(arch_pc)];
        check(expected.present && (expected.operation inside {LOAD,STORE} || (expected.operation==TRAP && expected.cause inside {5,7})),"unexpected architectural D access");
        address=regs_ref[expected.rs1]+expected.imm;
        check(pre_d_addr==address && pre_d_write==(expected.operation==STORE || expected.cause==7) &&
            d_req_size_o==2 && d_req_wstrb_o==(pre_d_write?15:0),"D semantic address and lanes");
        check(!pre_d_write || pre_d_data==regs_ref[expected.rs2],"D store source dependency");
        d_owned=1; d_accepted=0; d_address=pre_d_addr; d_tag=pre_d_tag;
        d_write=pre_d_write; d_data=pre_d_data; d_age=0; d_offers++;
        d_accept_delay=d_accept_setting; d_response_delay=d_response_setting;
        d_status=d_address==d_fault_address?2'd1:2'd0;
      end
      /* registered kills must identify existing live stage owners. */
      for (int stage=0;stage<5;stage++) begin
        /* cancellation cannot name a token from another stage or epoch. */
        if (kill_valid_o[stage]) begin
          id=int'(kill_uid_o[stage]);
          check(previous_valid[stage] && id<CAPACITY && live[id] && previous[stage].uid==kill_uid_o[stage],
              "killed instruction owner");
          live[id]=0; killed++;
        end
      end
      /* an IRQ redirects only at the independently maintained retired instruction boundary. */
      if (irq_valid_o) begin
        check(wake_on_idle && !trace_o.valid && arch_pc==38 && global_enable && enable_ref[11] && manual_levels[11],
            "IRQ eligibility and halfword boundary");
        check(irq_pc_o==arch_pc && mepc_o==arch_pc && irq_cause_o==32'h8000000b &&
            mcause_o==32'h8000000b && mtval_o==0 && redirect_valid_o && redirect_pc_o==vector_ref,
            "IRQ preserves halfword continuation PC");
        epc_ref=arch_pc; arch_pc=vector_ref; global_enable=0; interrupts++;
      end
      /* retirement is compared against program semantics and independently maintained registers. */
      if (trace_o.valid) begin
        id=int'(trace_o.uid); expected=program_ref[image_index(arch_pc)];
        check(id<CAPACITY && live[id] && trace_o.order==64'(next_order),"single ordered retirement owner");
        check(expected.present && trace_o.packet.pc==arch_pc,"instruction start PC sequence");
        observed_raw=trace_o.packet.raw; observed_value=trace_o.value;
        /* this detector changes observed bytes without changing the independent program image. */
        if ($test$plusargs("mutate_raw") && trace_o.packet.length==2 && !mutation_applied) begin
          observed_raw^=32'h10; mutation_applied=1;
        end
        check(observed_raw==expected.raw && trace_o.packet.raw_valid==expected.raw_valid &&
            trace_o.packet.length==expected.length,"original bits and length preserved");
        check(originals[id].pc==trace_o.packet.pc && originals[id].raw==trace_o.packet.raw &&
            originals[id].length==trace_o.packet.length && originals[id].raw_valid==trace_o.packet.raw_valid,
            "pipeline identity remains original");
        next_pc=arch_pc+{29'b0,expected.length}; value=0; write_reg=0; taken=0;
        check(defined_ref[expected.rs1] && defined_ref[expected.rs2],"program reads initialized operands");
        lhs=regs_ref[expected.rs1]; rhs=regs_ref[expected.rs2];
        /* each operation follows its requested semantics without reading expanded RTL metadata. */
        case (expected.operation)
          /* add with 32-bit wraparound. */
          ADDI: begin value=lhs+expected.imm; write_reg=expected.rd!=0; end
          /* write the upper immediate. */
          LUI: begin value=expected.imm; write_reg=expected.rd!=0; end
          /* add both register values. */
          ADD: begin value=lhs+rhs; write_reg=expected.rd!=0; end
          /* subtract with 32-bit wraparound. */
          SUB: begin value=lhs-rhs; write_reg=expected.rd!=0; end
          /* compare bitwise XOR. */
          XOR_OP: begin value=lhs^rhs; write_reg=expected.rd!=0; end
          /* compare bitwise OR. */
          OR_OP: begin value=lhs|rhs; write_reg=expected.rd!=0; end
          /* compare bitwise AND. */
          AND_OP: begin value=lhs&rhs; write_reg=expected.rd!=0; end
          /* mask the source with the signed immediate. */
          ANDI: begin value=lhs&expected.imm; write_reg=expected.rd!=0; end
          /* shift left using five amount bits. */
          SLL: begin value=lhs<<expected.imm[4:0]; write_reg=expected.rd!=0; end
          /* shift right without sign extension. */
          SRL: begin value=lhs>>expected.imm[4:0]; write_reg=expected.rd!=0; end
          /* shift right with sign extension. */
          SRA: begin value=32'($signed(lhs)>>>expected.imm[4:0]); write_reg=expected.rd!=0; end
          /* compare exact build extension identity. */
          MISA: begin value=32'h40000100|(M_ENABLED?32'h1000:0)|(C_ENABLED?4:0); write_reg=1; end
          /* compare low-half multiplication. */
          MUL_OP: begin value=lhs*rhs; write_reg=expected.rd!=0; end
          /* guarded signed quotient arithmetic supplies an independent late-producer result. */
          DIV_OP: begin
            value=rhs==0 ? 32'hffffffff : lhs==32'h80000000 && rhs==32'hffffffff ? lhs : 32'($signed(lhs)/$signed(rhs));
            write_reg=expected.rd!=0;
          end
          /* CSR reads compare the independently recorded original trap PC. */
          EPC_READ: begin value=epc_ref; write_reg=1; end
          /* mepc writes clear bit zero while preserving halfword target alignment. */
          EPC_WRITE: epc_ref=lhs&32'hfffffffe;
          /* the test uses only direct, naturally aligned trap vectors. */
          VECTOR_WRITE: vector_ref=lhs&32'hfffffffc;
          /* MRET transfers to the independently modeled WARL mepc value. */
          RETURN: begin next_pc=epc_ref; taken=1; global_enable=1; end
          /* CSR writes change interrupt eligibility only at their architectural boundary. */
          MIE_WRITE: enable_ref=lhs&32'h888;
          /* the fixture uses only the MIE field of mstatus. */
          STATUS_WRITE: global_enable=lhs[3];
          /* WFI itself retires before the retained event arrives. */
          WAIT_IRQ: begin end
          /* compute the target and original-length link. */
          JUMP: begin value=next_pc; write_reg=expected.rd!=0; next_pc=arch_pc+expected.imm; taken=1; links++; end
          /* clear target bit zero after reading the old source. */
          JREG: begin value=next_pc; write_reg=expected.rd!=0; next_pc=(lhs+expected.imm)&32'hfffffffe; taken=1; links++; end
          /* compare equal operands. */
          BEQ: begin taken=lhs==rhs; next_pc=taken?arch_pc+expected.imm:next_pc; branches++; end
          /* compare unequal operands. */
          BNE: begin taken=lhs!=rhs; next_pc=taken?arch_pc+expected.imm:next_pc; branches++; end
          /* loads compare separately maintained RAM or MMIO state. */
          LOAD: begin
            address=lhs+expected.imm;
            value=address[31:12]==20'h40000 ? 32'(mmio_ref):architectural_ram[address[9:2]];
            write_reg=expected.rd!=0; retired_reads++;
            /* side effects occur even when the destination is x0. */
            if (address[31:12]==20'h40000) mmio_ref++;
          end
          /* committed stores update reference memory after their independently checked bus effect. */
          STORE: begin
            address=lhs+expected.imm; retired_writes++;
            /* ordinary and effectful target spaces retain distinct reference semantics. */
            if (address[31:12]==20'h40000) mmio_ref++;
            /* stack and compact-register RAM accesses use their architectural address. */
            else architectural_ram[address[9:2]]=rhs;
          end
          NOP: hints++;
          /* defer fault checks to the precise trap comparator. */
          TRAP: begin end
          default: check(0,"unknown independent operation");
        endcase
        /* synchronous faults preserve the instruction start even when a later parcel fails. */
        if (expected.operation==TRAP) begin
          observed_epc=mepc_o;
          /* mutate only the observed trap PC to calibrate the original-start checker. */
          if ($test$plusargs("mutate_epc") && expected.cause==1 && !mutation_applied) begin
            observed_epc+=2; mutation_applied=1;
          end
          check(trace_o.trap && trace_o.packet.cause==expected.cause && trace_o.packet.mtval==expected.tval &&
              observed_epc==arch_pc && mcause_o==expected.cause && mtval_o==expected.tval,
              "precise fault and instruction start PC");
          check(!trace_o.rd_write && redirect_valid_o && redirect_pc_o==vector_ref,"trap has no register effect");
          traps++; epc_ref=arch_pc;
          /* selected trap cases execute a real CSR handler and return to a halfword target. */
          if (expected.imm==1) arch_pc=vector_ref;
          /* ordinary terminal traps stop issue while exposed fetch requests still drain. */
          else begin terminal=1; run_enable=0; end
          /* both fault positions have independent required coverage. */
          if (expected.cause==1 && expected.tval==trace_o.packet.pc) first_faults++;
          /* the second parcel retains only the available low instruction halfword. */
          if (expected.cause==1 && expected.tval==trace_o.packet.pc+2) second_faults++;
        end
        /* successful instructions preserve exact writes, targets and physical-effect counts. */
        else begin
          /* the link detector exercises the actual rd-result comparison. */
          if ($test$plusargs("mutate_link") && write_reg && expected.operation inside {JUMP,JREG} && !mutation_applied) begin
            observed_value+=2; mutation_applied=1;
          end
          check(!trace_o.trap && trace_o.rd_write==write_reg,"instruction legality and write mask");
          check(!write_reg || (trace_o.rd==5'(expected.rd) && observed_value==value),"architectural register result");
          check(trace_o.next_pc==next_pc && redirect_valid_o==taken && (!taken || redirect_pc_o==next_pc),
              "architectural next PC and redirect");
          /* reference registers change only after a successful ordered retirement. */
          if (write_reg) begin regs_ref[expected.rd]=value; defined_ref[expected.rd]=1; end
          retired++; compressed_retired+=int'(expected.length==2);
          straddled_retired+=int'(expected.length==4 && arch_pc[1]);
          arch_pc=next_pc;
        end
        retirement_digest=(retirement_digest^{trace_o.packet.pc,trace_o.packet.raw})*64'h100000001b3;
        retirement_digest=(retirement_digest^{trace_o.next_pc,trace_o.rd_write?trace_o.value:32'b0})*64'h100000001b3;
        retirement_digest=(retirement_digest^{trace_o.packet.mtval,trace_o.packet.cause})*64'h100000001b3;
        live[id]=0; next_order++;
      end
      /* input ownership is allocated exactly once on its valid/ready transfer. */
      if (input_fire) begin
        check(next_uid<CAPACITY && !live[next_uid],"new instruction UID allocation");
        live[next_uid]=1; originals[next_uid]=accepted_packet; next_uid++;
      end
      /* the independently observed stage vector must conserve every live instruction. */
      for (int uid=0;uid<next_uid;uid++) begin
        count=0;
        /* each UID has at most one architectural pipeline owner. */
        for (int stage=0;stage<5;stage++) count+=int'(stage_valid_o[stage] && stage_token_o[stage].uid==64'(uid));
        check(count==int'(live[uid]),"instruction conservation across stalls and kills");
      end
      /* held instructions still own exactly one stage and cannot modify architectural state. */
      if (|hold_i) begin held_edges++; observed_holds|=hold_i; end
      check(regs_ref[0]==0,"x0 reference invariant");
    end
  end

  /* drive a full edge after all previous nonblocking updates and checker activity settle. */
  task automatic tick;
    /* randomized pipeline pressure cannot block the independent target service clocks. */
    if (grid_holds) hold_i=5'b1<<3'(case_steps%5);
    /* seeded stage stalls complement the deterministic all-stage hold grid. */
    else if (random_holds) begin
      /* exercise each stage independently instead of freezing the whole pipe together. */
      for (int stage=0;stage<5;stage++) hold_i[stage]=(random_word()%8)==0;
    end
    #2; clk_i=1; #2; clk_i=0;
  endtask

  /* begin a new isolated case with reproducible memory and cleared control schedules. */
  task automatic begin_case;
    run_enable=0; random_holds=0; hold_i=0; wake_on_idle=0; manual_levels=0; targeted_mode=0; targeted_address=0;
    d_fault_address='1; acceptance_limit=4; response_limit=6; d_accept_setting=2; d_response_setting=3;
    force_branch_hold=0; fixed_service=0; grid_holds=0; case_steps=0; builder_pc=0; cases++;
    /* instruction storage starts reserved so an unintended path cannot silently become valid. */
    for (int n=0;n<WORDS;n++) begin image[n]=0; image_fault[n]=0; program_ref[n]='0; end
    /* distinct nonzero RAM values expose wrong lanes or repeated store effects. */
    for (int n=0;n<256;n++) begin physical_ram[n]=32'h8f000000+32'(n); architectural_ram[n]=physical_ram[n]; end
    cold_reset_i=1; tick(); cold_reset_i=0; tick(); tick();
  endtask

  /* run until the independently specified terminal and drain every exposed bus owner. */
  task automatic execute_program(input bit stalls);
    run_enable=1; random_holds=stalls;
    /* every case has a finite progress deadline and first-failure trace. */
    while (!terminal && case_steps<16000) begin
      /* the event remains pending after the handler masks it and returns. */
      if (wake_on_idle && idle_o) manual_levels=32'h800;
      /* delay branch retirement until the wrong-path second parcel is visibly owned. */
      if (force_branch_hold) begin
        hold_i[4]=1;
        /* release either before acceptance or after acceptance, according to the case. */
        if (i_owned && i_address==targeted_address && (targeted_mode==1 || i_accepted)) begin
          force_branch_hold=0; hold_i[4]=0;
        end
      end
      tick();
    end
    check(terminal,"program termination deadline");
    run_enable=0; random_holds=0; grid_holds=0; hold_i=0;
    /* redirects leave old physical owners alive until their one response returns. */
    repeat (70) tick();
    check(!i_owned && !d_owned && !fetch_busy && !mem_busy_o,"all exposed requests drain");
    check(case_reads==retired_reads && case_writes==retired_writes && mmio_effects==mmio_ref,
        "physical effects match permitted retirement");
    /* the trap kills every younger token; no live instruction can disappear silently. */
    for (int uid=0;uid<next_uid;uid++) check(!live[uid],"terminal instruction conservation");
  endtask

  /* exercise every supported compact format together with dependency and memory effects. */
  task automatic arithmetic_program;
    begin_case(); initialize_program();
    emit(32'h30102ff3,4,MISA,31,0,0,0);
    emit_c(0,9,0,0,124); emit_c(6,2,2,0,-32); emit_c(6,2,2,0,32);
    emit_c(5,10,0,0,-17); emit_c(7,11,0,0,32'hfffff000);
    emit_c(3,10,0,0,3); emit_c(18,10,0,0,3); emit_c(8,10,0,0,1);
    emit_c(9,11,0,0,5); emit_c(10,11,0,0,-13);
    emit_c(11,10,0,11,0); emit_c(12,10,0,11,0); emit_c(13,10,0,11,0); emit_c(14,10,0,11,0);
    emit_c(21,12,0,10,0); emit_c(24,12,0,11,0);
    emit_c(2,0,8,12,124); emit_c(1,13,8,0,124);
    emit_c(25,0,2,13,252); emit_c(19,14,2,0,252);
    /* actual 32-bit arithmetic starts in the upper half of an instruction word. */
    if (builder_pc%4==0) emit(32'h00000001,2,NOP,0,0,0,0);
    emit(enc_i('h13,15,14,0,-7),4,ADDI,15,14,0,-7);
    emit(32'h40000437,4,LUI,8,0,0,32'h40000000);
    emit_c(1,9,8,0,0); emit_c(1,10,8,0,0); emit_c(2,0,8,10,4);
    emit(enc_i('h03,0,8,2,0),4,LOAD,0,8,0,0);
    finish_program(); execute_program(1);
  endtask

  /* randomized programs compare original encoding metadata with independent operand semantics. */
  task automatic random_program;
    int choice, rd, rs2, immediate_value;
    begin_case(); initialize_program();
    /* mixed instruction widths alternate alignment and stress compact-register dependencies. */
    for (int n=0;n<128;n++) begin
      choice=int'(program_random_word()%20); rd=9+int'(program_random_word()%7); rs2=9+int'(program_random_word()%7);
      immediate_value=int'(program_random_word()%63)-31;
      /* nonzero compact immediates avoid accidentally changing an arithmetic case into a HINT. */
      if (immediate_value==0) immediate_value=1;
      /* each generator arm supplies its own expected operation and sources. */
      case (choice)
        0: emit_c(0,rd,0,0,4*(1+program_random_word()%255));
        1: emit_c(3,rd,0,0,32'(immediate_value));
        2: emit_c(5,rd,0,0,32'(immediate_value));
        3: emit_c(7,rd,0,0,32'(immediate_value)<<12);
        4: emit_c(18,rd,0,0,1+program_random_word()%31);
        5: emit_c(8,rd,0,0,1+program_random_word()%31);
        6: emit_c(9,rd,0,0,1+program_random_word()%31);
        7: emit_c(10,rd,0,0,32'(immediate_value));
        8: emit_c(11,rd,0,rs2,0);
        9: emit_c(12,rd,0,rs2,0);
        10: emit_c(13,rd,0,rs2,0);
        11: emit_c(14,rd,0,rs2,0);
        12: emit_c(21,rd,0,rs2,0);
        13: emit_c(24,rd,0,rs2,0);
        14: emit_c(1,rd,8,0,4*(program_random_word()%32));
        15: emit_c(2,0,8,rs2,4*(program_random_word()%32));
        16: emit_c(19,rd,2,0,4*(program_random_word()%64));
        17: emit_c(25,0,2,rs2,4*(program_random_word()%64));
        18: emit(enc_i('h13,rd,rs2,0,32'(immediate_value)),4,ADDI,rd,rs2,0,32'(immediate_value));
        default: emit(32'h00000001,2,NOP,0,0,0,0);
      endcase
    end
    finish_program(); execute_program(1);
  endtask

  /* C.JALR reads old x1 before overwriting it with its two-byte link address. */
  task automatic control_program;
    begin_case(); initialize_program();
    check(builder_pc==136,"control program initializer layout");
    emit(32'h00000001,2,NOP,0,0,0,0);
    emit_c(4,1,0,0,262);
    emit_c(3,10,0,0,1);
    emit(enc_i('h13,1,0,0,451),4,ADDI,1,0,0,451);
    emit_c(23,1,1,0,0);
    emit(32'h00000001,2,NOP,0,0,0,0);
    emit(enc_j(5,350),4,JUMP,5,0,0,350);
    emit_c(5,9,0,0,0); emit_c(16,0,9,0,6);
    emit_c(22,0,0,0,0); emit(32'h00000001,2,NOP,0,0,0,0);
    emit(enc_i('h13,9,0,0,1),4,ADDI,9,0,0,1);
    emit_c(17,0,9,0,6); emit_c(22,0,0,0,0); emit(32'h00000001,2,NOP,0,0,0,0);
    emit_c(16,0,9,0,4); emit_c(5,9,0,0,0); emit_c(17,0,9,0,4); finish_program();
    builder_pc=400; emit_c(5,11,0,0,-3); emit_c(20,1,1,0,0);
    builder_pc=450; emit_c(5,12,0,0,9); emit_c(20,1,1,0,0);
    builder_pc=500; emit(enc_i('h13,13,0,0,23),4,ADDI,13,0,0,23);
    emit(enc_i('h67,0,5,0,0),4,JREG,0,5,0,0);
    execute_program(1);
  endtask

  /* every architectural C HINT family retires once without changing registers or devices. */
  task automatic hint_program;
    begin_case();
    emit(32'h00000001,2,NOP,0,0,0,0);
    emit({16'b0,enc_c(3,9,0,0,0)},2,NOP,0,0,0,0);
    emit({16'b0,enc_c(3,0,0,0,31)},2,NOP,0,0,0,0);
    emit({16'b0,enc_c(5,0,0,0,-32)},2,NOP,0,0,0,0);
    emit({16'b0,enc_c(7,0,0,0,4096)},2,NOP,0,0,0,0);
    emit({16'b0,enc_c(18,9,0,0,0)},2,NOP,0,0,0,0);
    emit({16'b0,enc_c(18,0,0,0,31)},2,NOP,0,0,0,0);
    emit({16'b0,enc_c(8,9,0,0,0)},2,NOP,0,0,0,0);
    emit({16'b0,enc_c(9,9,0,0,0)},2,NOP,0,0,0,0);
    emit({16'b0,enc_c(21,0,0,9,0)},2,NOP,0,0,0,0);
    emit({16'b0,enc_c(24,0,0,9,0)},2,NOP,0,0,0,0);
    finish_program(); execute_program(1);
  endtask

  /* reserved, custom and absent floating-point encodings trap at either halfword alignment. */
  task automatic illegal_program(input logic [15:0] raw, input bit upper);
    begin_case();
    /* a preceding C.NOP moves the illegal instruction to the upper fetched halfword. */
    if (upper) emit(32'h00000001,2,NOP,0,0,0,0);
    emit({16'b0,raw},2,TRAP,0,0,0,0);
    program_ref[image_index(32'(builder_pc-2))].cause=2;
    execute_program(1);
  endtask

  /* parcel errors retain the first instruction PC and only physically available original bits. */
  task automatic fetch_fault_program(input bit upper, second);
    int pc, index;
    logic [31:0] word;
    begin_case();
    /* C enables a 32-bit instruction at the upper halfword of the fetched word. */
    if (upper) emit(32'h00000001,2,NOP,0,0,0,0);
    pc=builder_pc; word=enc_i('h13,1,0,0,7);
    emit(word,4,TRAP,0,0,0,0); index=image_index(32'(pc));
    program_ref[index].cause=1; program_ref[index].tval=32'(pc)+(second?2:0);
    image_fault[index+int'(second)]=1;
    /* a successful low parcel establishes four-byte framing before the high-parcel fault. */
    if (second) begin program_ref[index].raw=word&32'hffff; program_ref[index].raw_valid=3; end
    /* an unavailable first parcel cannot establish any instruction length. */
    else begin
      program_ref[index].length=0;
      program_ref[index].raw=C_ENABLED?0:word&32'hffff0000;
      program_ref[index].raw_valid=C_ENABLED?0:12;
    end
    execute_program(1);
  endtask

  /* a revoked second parcel drains with its error and cannot fault the jump target stream. */
  task automatic stale_fault_program(input int mode);
    int before_stale, before_simultaneous;
    begin_case(); before_simultaneous=simultaneous_discard;
    emit_c(15,0,0,0,64);
    emit(enc_i('h13,1,0,0,7),4,ADDI,1,0,0,7);
    image_fault[2]=1;
    builder_pc=64; emit_c(5,9,0,0,7); finish_program();
    targeted_mode=mode; targeted_address=4; force_branch_hold=1; before_stale=stale_replies;
    execute_program(0);
    check(stale_replies>before_stale,"wrong-path second-parcel error actually discarded");
    /* the directed reply must coincide with the actual manager redirect input. */
    if (mode==3) check(simultaneous_discard>before_simultaneous,"same-edge redirect and second-parcel response");
  endtask

  /* execute a safe last parcel and attribute denied continuation without touching a device. */
  task automatic guard_fault_program(input bit wide, upper);
    logic [31:0] target, word;
    int unused_index;
    begin_case(); target=upper?32'h60000006:32'h60000000;
    emit(32'h600000b7,4,LUI,1,0,0,32'h60000000);
    emit(enc_i('h67,0,1,0,upper?6:0),4,JREG,0,1,0,upper?6:0);
    builder_pc=int'(target); unused_index=image_index(target);
    /* wide instructions require an inaccessible second parcel and report their start address. */
    if (wide) begin
      word=enc_i('h13,9,0,0,7); emit(word,4,TRAP,0,0,0,0);
      program_ref[unused_index].raw=word&32'hffff; program_ref[unused_index].raw_valid=3;
      program_ref[unused_index].cause=1; program_ref[unused_index].tval=target+2;
    end
    /* a complete C instruction does not fetch or fault its unused inaccessible neighbor. */
    else begin
      emit_c(5,9,0,0,7); unused_index=image_index(target+2);
      program_ref[unused_index]='{present:1,raw:0,raw_valid:0,length:0,operation:TRAP,
          rd:0,rs1:0,rs2:0,imm:0,cause:1,tval:target+2};
    end
    execute_program(1);
  endtask

  /* a blocking data rejection outranks the younger already-fetched compact breakpoint. */
  task automatic older_fault_program;
    int unused_index;
    begin_case(); emit(32'h20000437,4,LUI,8,0,0,32'h20000000);
    unused_index=image_index(32'(builder_pc)); emit_c(1,9,8,0,0);
    program_ref[unused_index].operation=TRAP; program_ref[unused_index].cause=5; program_ref[unused_index].tval=32'h20000000;
    emit_c(22,0,0,0,0); emit_c(2,0,8,9,4);
    d_fault_address=32'h20000000; d_accept_setting=9; d_response_setting=14;
    execute_program(1);
  endtask

  /* base-only framing and optional M instructions retain their separate configuration identity. */
  task automatic base_program;
    begin_case(); initialize_program(); emit(32'h30102ff3,4,MISA,31,0,0,0);
    emit(enc_i('h13,9,10,0,-3),4,ADDI,9,10,0,-3);
    finish_program(); execute_program(1);
    begin_case(); initialize_program();
    /* a C-enabled build deliberately makes the optional M instruction straddle two fetched words. */
    if (C_ENABLED) emit(32'h00000001,2,NOP,0,0,0,0);
    emit(32'h02b50633,4,M_ENABLED?MUL_OP:TRAP,12,10,11,0);
    /* disabled M must trap on the original four-byte encoding. */
    if (!M_ENABLED) program_ref[image_index(32'(builder_pc-4))].cause=2;
    finish_program(); execute_program(1);
  endtask


  /* the trap handler reads original halfword mepc and MRET uses a halfword-aligned written target. */
  task automatic trap_return_program;
    begin_case();
    emit(enc_i('h13,1,0,0,256),4,ADDI,1,0,0,256);
    emit(enc_i('h73,0,1,1,'h305),4,VECTOR_WRITE,0,1,0,0);
    emit(32'h00000001,2,NOP,0,0,0,0);
    emit_c(22,0,0,0,0); program_ref[5].imm=1;
    builder_pc=14; emit_c(5,9,0,0,7);
    emit(enc_i('h13,10,9,0,1),4,ADDI,10,9,0,1); emit_c(22,0,0,0,0);
    builder_pc=256; emit(enc_i('h73,5,0,2,'h341),4,EPC_READ,5,0,0,0);
    emit(enc_i('h13,5,5,0,5),4,ADDI,5,5,0,5);
    emit(enc_i('h73,0,5,1,'h341),4,EPC_WRITE,0,5,0,0);
    emit(32'h30200073,4,RETURN,0,0,0,0);
    execute_program(1);
    check(regs_ref[5]==15 && regs_ref[10]==8,"trap return halfword sequence");
  endtask

  /* compact data legality and LSU checks must reject accesses before any device effect. */
  task automatic compact_memory_faults;
    int unused_index, base;
    begin_case(); emit(32'h40000137,4,LUI,2,0,0,32'h40000000);
    emit(32'h00000001,2,NOP,0,0,0,0);
    emit(32'h00004002,2,TRAP,0,2,0,0); program_ref[3].cause=2;
    execute_program(1);
    begin_case(); emit(32'h40000137,4,LUI,2,0,0,32'h40000000);
    emit_c(25,0,2,0,0); emit_c(22,0,0,0,0); execute_program(1);
    /* both stack and compact-register forms cover reads, writes and natural alignment. */
    for (int stack=0;stack<2;stack++) begin
      /* each access class has its own synchronous cause and no external request. */
      for (int store=0;store<2;store++) begin
        begin_case(); base=stack!=0?2:8;
        emit({20'h20000,5'(base),7'h37},4,LUI,base,0,0,32'h20000000);
        emit(enc_i('h13,base,base,0,1),4,ADDI,base,base,0,1);
        emit(enc_i('h13,9,0,0,7),4,ADDI,9,0,0,7);
        emit(32'h00000001,2,NOP,0,0,0,0); unused_index=image_index(32'(builder_pc));
        emit_c(stack!=0?(store!=0?25:19):(store!=0?2:1),9,base,9,0);
        program_ref[unused_index].operation=TRAP; program_ref[unused_index].cause=store!=0?6:4;
        program_ref[unused_index].tval=32'h20000001; execute_program(1);
        begin_case();
        emit({20'h50002,5'(base),7'h37},4,LUI,base,0,0,32'h50002000);
        emit(enc_i('h13,9,0,0,7),4,ADDI,9,0,0,7);
        emit(32'h00000001,2,NOP,0,0,0,0); unused_index=image_index(32'(builder_pc));
        emit_c(stack!=0?(store!=0?25:19):(store!=0?2:1),9,base,9,0);
        program_ref[unused_index].operation=TRAP; program_ref[unused_index].cause=store!=0?7:5;
        program_ref[unused_index].tval=32'h50002000; d_fault_address=32'h50002000;
        execute_program(1);
      end
    end
  endtask


  /* a word crossing address wrap preserves its original PC while its high half shares boot bytes. */
  task automatic wrapped_instruction_program;
    begin_case();
    emit(32'h0080006f,4,JUMP,0,0,0,8);
    builder_pc=2; emit_c(0,8,2,0,64); emit_c(22,0,0,0,0);
    builder_pc=8; emit(enc_i('h13,2,0,0,128),4,ADDI,2,0,0,128);
    emit(enc_i('h13,30,0,0,17),4,ADDI,30,0,0,17);
    emit(enc_i('h13,1,0,0,-1),4,ADDI,1,0,0,-1);
    emit(enc_i('h67,0,1,0,0),4,JREG,0,1,0,0);
    builder_pc=-2; emit(32'h006f0493,4,ADDI,9,30,0,6);
    execute_program(1);
    check(regs_ref[9]==23 && regs_ref[8]==192,"wrapped instruction assembled from both address ends");
  endtask

  /* WFI at PC34 straddles a word and an actual retained IRQ resumes the halfword PC38. */
  task automatic interrupt_program;
    int before_interrupts;
    begin_case(); before_interrupts=interrupts;
    emit(enc_i('h13,1,0,0,256),4,ADDI,1,0,0,256);
    emit(enc_i('h73,0,1,1,'h305),4,VECTOR_WRITE,0,1,0,0);
    emit(32'h00001137,4,LUI,2,0,0,4096);
    emit(enc_i('h13,2,2,0,-2048),4,ADDI,2,2,0,-2048);
    emit(enc_i('h73,0,2,1,'h304),4,MIE_WRITE,0,2,0,0);
    emit(enc_i('h13,3,0,0,8),4,ADDI,3,0,0,8);
    emit(enc_i('h73,0,3,1,'h300),4,STATUS_WRITE,0,3,0,0);
    emit(32'h00000001,2,NOP,0,0,0,0);
    emit(enc_i('h13,9,0,0,7),4,ADDI,9,0,0,7);
    emit(32'h10500073,4,WAIT_IRQ,0,0,0,0);
    emit_c(3,9,9,0,1); finish_program();
    builder_pc=256; emit(enc_i('h73,0,0,1,'h304),4,MIE_WRITE,0,0,0,0);
    emit(32'h00000001,2,NOP,0,0,0,0); emit(32'h30200073,4,RETURN,0,0,0,0);
    wake_on_idle=1; execute_program(1);
    check(interrupts==before_interrupts+1 && regs_ref[9]==8 && manual_levels[11] && enable_ref==0,
          "retained IRQ and halfword MRET continuation");
  endtask


  /* enumerate finite independent service delays at both instruction halfword alignments. */
  task automatic service_grid;
    /* first-valid acceptance and registered post-acceptance response schedules vary independently. */
    for (int accept_wait=0;accept_wait<4;accept_wait++) begin
      /* response wait zero means the next registered edge, never a combinational acceptance reply. */
      for (int response_wait=0;response_wait<4;response_wait++) begin
        /* each schedule runs an aligned and a straddling wide instruction. */
        for (int upper=0;upper<2;upper++) begin
          begin_case(); initialize_program();
          /* an actual C instruction changes the following wide instruction's fetch-word alignment. */
          if (upper!=0) emit(32'h00000001,2,NOP,0,0,0,0);
          emit(enc_i('h13,9,0,0,5),4,ADDI,9,0,0,5);
          emit_c(2,0,8,9,0); emit_c(1,10,8,0,0); emit_c(17,0,10,0,4);
          emit_c(22,0,0,0,0); finish_program();
          fixed_service=1; acceptance_limit=accept_wait; response_limit=response_wait;
          d_accept_setting=accept_wait; d_response_setting=response_wait; grid_holds=1;
          execute_program(0);
        end
      end
    end
  endtask


  /* a straddling signed divide forwards its late result through compact arithmetic and branch operands. */
  task automatic divide_dependency_program;
    int before_wait;
    begin_case(); initialize_program(); before_wait=late_c_wait;
    emit(enc_i('h13,10,0,0,-17),4,ADDI,10,0,0,-17);
    emit(enc_i('h13,11,0,0,3),4,ADDI,11,0,0,3);
    emit(32'h00000001,2,NOP,0,0,0,0);
    emit(32'h02b544b3,4,DIV_OP,9,10,11,0);
    emit_c(3,9,9,0,5); emit_c(16,0,9,0,4); emit_c(22,0,0,0,0); finish_program();
    execute_program(1);
    check(regs_ref[9]==0,"late divide reaches compressed ALU and branch");
    /* diagnostic occupancy cannot overlap the producer and consumer by construction. */
    if (!DIAGNOSTIC) check(late_c_wait>before_wait,"compressed consumer actually waits for division");
  endtask

  /* fixed and seeded programs cover both framing configurations without conflating their claims. */
  initial begin
    void'($value$plusargs("seed=%d",seed)); rng=seed; program_rng=seed;
    base_program();
    /* real compressed execution is separately elaborated from legacy base framing. */
    if (C_ENABLED) begin
      arithmetic_program(); random_program(); control_program(); hint_program();
      trap_return_program(); compact_memory_faults(); wrapped_instruction_program(); interrupt_program(); service_grid();
      /* this dependency scenario requires the separately enabled M extension. */
      if (M_ENABLED) divide_dependency_program();
      /* all major illegal encoding families execute at both instruction alignments. */
      for (int upper=0;upper<2;upper++) begin
        illegal_program(16'h0000,1'(upper)); illegal_program(16'h6101,1'(upper));
        illegal_program(16'h6001,1'(upper)); illegal_program(16'h4002,1'(upper));
        illegal_program(16'h8002,1'(upper)); illegal_program(16'h9001,1'(upper));
        illegal_program(16'h1002,1'(upper)); illegal_program(16'h2000,1'(upper));
        illegal_program(16'h6000,1'(upper)); illegal_program(16'h9c01,1'(upper));
        fetch_fault_program(1'(upper),0); fetch_fault_program(1'(upper),1);
        guard_fault_program(0,1'(upper)); guard_fault_program(1,1'(upper));
      end
      stale_fault_program(1); stale_fault_program(2); stale_fault_program(3); older_fault_program();
      check(compressed_retired>150 && straddled_retired>10 && links>=6 && branches>=4 && hints>=12,
          "mixed-width operation coverage");
      check(first_faults>=4 && second_faults>=4 && stale_replies>=2,"fetch fault position coverage");
      check(interrupts>0 && idle_edges>0 && pending_edges>0,"real frontend WFI and IRQ coverage");
    end
    /* a short prefix remains illegal and a halfword target remains misaligned without C. */
    else begin
      fetch_fault_program(0,0); fetch_fault_program(0,1);
      begin_case(); image[0]=16'h0001; image[1]=16'h0001;
      program_ref[0]='{present:1,raw:32'h00010001,raw_valid:15,length:0,operation:TRAP,
          rd:0,rs1:0,rs2:0,imm:0,cause:2,tval:0}; execute_program(1);
      begin_case(); emit(enc_j(1,2),4,TRAP,0,0,0,0);
      program_ref[0].cause=0; program_ref[0].tval=2; execute_program(1);
    end
    check(i_offers==i_accepts && i_accepts==i_replies && d_offers==d_accepts && d_accepts==d_replies,
          "global physical request conservation");
    check(observed_holds==31 && held_edges>10,"every stage receives backpressure");
    check(!$test$plusargs("mutate_raw") && !$test$plusargs("mutate_epc") &&
        !$test$plusargs("mutate_link") && !$test$plusargs("mutate_effect"),"requested detector did not fire");
    $display("C_EXEC_PASS C=%0d M=%0d diagnostic=%0d forwarding=%0d seed=%0d cases=%0d edges=%0d checks=%0d retired=%0d traps=%0d killed=%0d compressed=%0d straddled=%0d hints=%0d links=%0d branches=%0d first_faults=%0d second_faults=%0d stale=%0d I_offers=%0d I_accepts=%0d I_replies=%0d D_offers=%0d D_accepts=%0d D_replies=%0d reads=%0d writes=%0d holds=%0d max_I_accept=%0d max_D_accept=%0d IRQ=%0d idle=%0d pending=%0d simultaneous_discard=%0d late_C_wait=%0d program_digest=%016x retirement_digest=%016x effect_digest=%016x",
        C_ENABLED,M_ENABLED,DIAGNOSTIC,FORWARDING,seed,cases,edges,checks,retired,traps,killed,
        compressed_retired,straddled_retired,hints,links,branches,first_faults,second_faults,stale_replies,
        i_offers,i_accepts,i_replies,d_offers,d_accepts,d_replies,reads,writes,held_edges,max_i_wait,max_d_wait,interrupts,idle_edges,pending_edges,simultaneous_discard,late_c_wait,program_digest,retirement_digest,effect_digest);
    $finish;
  end
endmodule
