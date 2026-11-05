/* verify trace phase alignment and finite capture identity without affecting CPU state. */
module drg5_observe_tb #(
  parameter integer PROFILE=0
);
  import drg5_control_pkg::*;
  localparam integer SB=(PROFILE==1 || PROFILE>=4)?3:64,
      EB=(PROFILE==2 || PROFILE==5)?2:64, RB=PROFILE>=3?3:64;
  logic clk_i, capture_reset_i;
  logic cold_reset_i, isolated_i, hart_reset_i;
  logic debug_mode_i, debug_ebreak_entry_i;
  logic [4:0] hold_i, stage_valid_i;
  logic [3:0] transfer_i;
  drg5_control_pkg::token_t stage_token_i [0:4];
  logic in_valid_i, in_ready_i;
  drg5_control_pkg::packet_t in_packet_i;
  logic [31:0] mip_levels_i;
  logic [63:0] mcycle_i, minstret_i;
  logic [31:0] mcountinhibit_i;
  drg5_control_pkg::trace_t trace_i;
  logic [4:0] kill_valid_i;
  logic [63:0] kill_uid_i [0:4];
  logic irq_valid_i, idle_i, fatal_i;
  logic [31:0] irq_pc_i, irq_cause_i;
  drg5_control_pkg::fatal_record_t fatal_record_i;
  logic redirect_valid_i;
  logic [31:0] redirect_pc_i;
  logic flush_valid_i, flush_ready_i, flush_aborted_i;
  logic [31:0] flush_pc_i;
  logic mem_launch_i;
  logic d_req_valid_i, d_req_ready_i, d_req_write_i;
  logic [31:0] d_req_addr_i, d_req_wdata_i, d_req_tag_i;
  logic [1:0] d_req_size_i;
  logic [3:0] d_req_wstrb_i;
  logic d_rsp_valid_i, d_rsp_ready_i;
  logic [31:0] d_rsp_tag_i, d_rsp_rdata_i;
  logic [1:0] d_rsp_status_i;
  logic i_req_valid_i, i_req_ready_i;
  logic [31:0] i_req_addr_i, i_req_tag_i;
  logic [1:0] i_req_parcels_i;
  logic i_rsp_valid_i, i_rsp_ready_i, i_drop_i, i_fatal_i;
  logic [2:0] i_fatal_reason_i;
  logic [31:0] i_rsp_tag_i, i_rsp_data_i;
  logic [1:0] i_rsp_parcels_i, i_rsp_fault_i, i_rsp_status_i;
  observe_t record_o, stimulus, observed;
  longint unsigned sequence_ref=0, epoch_ref=0, retired_ref=0;
  bit old_reset=1;
  logic [2:0] loss_ref=0;
  int checks=0, edges=0, valid_records=0, lost_records=0, seed=0;
  logic [31:0] rng;
  bit mutated=0;

  /* each independently elaborated reduced width reaches one exhaustion boundary quickly. */
  drg5_observe #(.SEQUENCE_BITS(SB), .EPOCH_BITS(EB), .RETIRED_BITS(RB)) dut (.*);

  /* xorshift state varies every field without a correlated low-bit linear sequence. */
  function automatic logic [31:0] random_word;
    rng=rng^(rng<<13); rng=rng^(rng>>17); rng=rng^(rng<<5); return rng;
  endfunction

  /* identify the first lost or misaligned observation by its exact capture edge. */
  task automatic check(input bit condition,input string message);
    checks++;
    /* a failing trace cannot be silently used as an architectural execution record. */
    if (!condition) $fatal(1,"OBSERVE_FAIL profile=%0d seed=%0d edge=%0d: %s",PROFILE,seed,edges,message);
  endtask

  /* supply arbitrary pre-edge inputs and independently chosen post-edge output values. */
  task automatic populate;
    /* every bit of the packed payload receives independent changing stimulus. */
    for (int bit_index=0;bit_index<$bits(observe_t);bit_index++) stimulus[bit_index]=1'(random_word()>>11);
    cold_reset_i=0; hart_reset_i=PROFILE==5?1'(!(edges%2)):PROFILE==2?1'(edges%2):1'(edges%11==0); isolated_i=1;
    debug_mode_i=stimulus.debug_mode; debug_ebreak_entry_i=stimulus.debug_ebreak_entry;
    hold_i=stimulus.hold; stage_valid_i=stimulus.stages_before; transfer_i=stimulus.transfers;
    in_valid_i=stimulus.input_accept; in_ready_i=1; in_packet_i=stimulus.input_packet;
    mip_levels_i=stimulus.irq_levels; mcycle_i=stimulus.cycle_before; minstret_i=stimulus.instret_before;
    mcountinhibit_i=stimulus.inhibit_before;
    flush_valid_i=stimulus.flush_accept; flush_ready_i=1; flush_pc_i=stimulus.flush_pc;
    mem_launch_i=stimulus.d_launch;
    d_req_valid_i=stimulus.d_offer; d_req_ready_i=1'(random_word()>>7); d_req_write_i=stimulus.d_write;
    stimulus.d_accept=d_req_valid_i && d_req_ready_i;
    d_req_addr_i=stimulus.d_addr; d_req_wdata_i=stimulus.d_wdata; d_req_tag_i=stimulus.d_tag;
    d_req_size_i=stimulus.d_size; d_req_wstrb_i=stimulus.d_strobes;
    d_rsp_valid_i=stimulus.d_response; d_rsp_ready_i=1; d_rsp_tag_i=stimulus.d_response_tag;
    d_rsp_rdata_i=stimulus.d_rdata; d_rsp_status_i=stimulus.d_status;
    i_req_valid_i=stimulus.i_offer; i_req_ready_i=1'(random_word()>>9);
    stimulus.i_accept=i_req_valid_i && i_req_ready_i;
    i_req_addr_i=stimulus.i_addr; i_req_tag_i=stimulus.i_tag; i_req_parcels_i=stimulus.i_parcels;
    i_rsp_valid_i=stimulus.i_response; i_rsp_ready_i=1; i_rsp_tag_i=stimulus.i_response_tag;
    i_rsp_data_i=stimulus.i_rdata; i_rsp_parcels_i=stimulus.i_response_parcels;
    i_rsp_fault_i=stimulus.i_fault; i_rsp_status_i=stimulus.i_status; i_drop_i=stimulus.i_drop;
    /* admission is sampled before transfers, while UID and terminal state are observed after. */
    for (int stage=0;stage<5;stage++) begin
      stage_token_i[stage].admitted=stimulus.admitted_before[stage];
      stage_token_i[stage].uid=64'(stage+500);
    end
    stage_token_i[3].uid=stimulus.d_launch_uid;
    stimulus.cold_reset=cold_reset_i; stimulus.hart_reset=hart_reset_i; stimulus.isolated=isolated_i;
    /* frequent real terminals and interspersed traps distinguish normal retirement from disposition. */
    stimulus.terminal.valid=1;
    stimulus.terminal.trap=PROFILE>=3?1'b0:1'(edges%3==1);
  endtask

  /* mimic registered core outputs changing only after the edge being observed. */
  task automatic drive_after;
    mcycle_i=stimulus.cycle_after; minstret_i=stimulus.instret_after; mcountinhibit_i=stimulus.inhibit_after;
    trace_i=stimulus.terminal; stage_valid_i=stimulus.stages_after; kill_valid_i=stimulus.kill_valid;
    irq_valid_i=stimulus.irq; irq_pc_i=stimulus.irq_pc; irq_cause_i=stimulus.irq_cause;
    idle_i=stimulus.idle; fatal_i=stimulus.fatal; fatal_record_i=stimulus.fatal_record;
    redirect_valid_i=stimulus.redirect; redirect_pc_i=stimulus.redirect_pc; flush_aborted_i=stimulus.flush_aborted;
    i_fatal_i=stimulus.i_fatal; i_fatal_reason_i=stimulus.i_fatal_reason;
    /* each lane has a distinct post-edge identity and admission value. */
    for (int stage=0;stage<5;stage++) begin
      kill_uid_i[stage]=stimulus.kill_uid[64*stage+:64];
      stage_token_i[stage].uid=stimulus.stage_uid[64*stage+:64];
      stage_token_i[stage].admitted=stimulus.admitted_after[stage];
    end
  endtask

  /* the oracle counts observations independently of architectural counter contents and writes. */
  task automatic tick;
    bit new_reset, normal;
    longint unsigned retired_before;
    new_reset=(cold_reset_i || hart_reset_i) && !old_reset;
    old_reset=cold_reset_i || hart_reset_i;
    #2; clk_i=1; #1;
    /* the preceding terminal remains stable through this sampling edge. */
    drive_after(); #1;
    edges++; normal=stimulus.terminal.valid && !stimulus.terminal.trap;
    /* a qualified rearm starts a declared new capture rather than hiding a gap. */
    if (capture_reset_i) begin
      sequence_ref=0; epoch_ref=0; retired_ref=0; loss_ref=0;
      check(!record_o.valid && record_o.overflow==0,"explicit capture rearm");
    end
    /* normal observations saturate their identity rather than wrapping it into old records. */
    else begin
      retired_before=retired_ref;
      /* a prior invalid record permanently ends the current capture. */
      if (loss_ref==0) begin
        if (sequence_ref==((64'b1<<SB)-1)) loss_ref[0]=1;
        else sequence_ref++;
        /* only a reset assertion transition consumes another epoch identity. */
        if (new_reset) begin
          if (epoch_ref==((64'b1<<EB)-1)) loss_ref[1]=1;
          else epoch_ref++;
        end
      end
      /* retirement identity exhaustion is visible on its own current terminal edge. */
      if (normal && retired_ref==((64'b1<<RB)-1)) loss_ref[2]=1;
      observed=record_o;
      /* calibrate the ordinary checker against a silently valid wrapped capture. */
      if ($test$plusargs("mutate_overflow") && loss_ref!=0 && !mutated) begin observed.valid=1; mutated=1; end
      check(observed.valid==(loss_ref==0) && observed.overflow==loss_ref,"capture loss policy");
      check(observed.sequence_id==sequence_ref && observed.epoch==epoch_ref,"capture sequence and epoch");
      /* invalid payloads are not advertised as a usable execution record. */
      if (loss_ref!=0) lost_records++;
      /* every valid record must retain all pre/post fields without a phase shift. */
      else begin
        retired_ref+=64'(normal); valid_records++;
        stimulus.valid=1; stimulus.overflow=0; stimulus.sequence_id=sequence_ref; stimulus.epoch=epoch_ref;
        stimulus.retired_before=retired_before; stimulus.retired_after=retired_ref;
        /* phase and retirement mutations must fail distinct ordinary comparisons. */
        if ($test$plusargs("mutate_phase") && !mutated) begin observed.cycle_before=observed.cycle_after; mutated=1; end
        /* a missing normal retirement must fail independently of counter snapshots. */
        if ($test$plusargs("mutate_retired") && normal && !mutated) begin observed.retired_after++; mutated=1; end
        check(observed.cycle_before==stimulus.cycle_before && observed.cycle_after==stimulus.cycle_after &&
            observed.instret_before==stimulus.instret_before && observed.instret_after==stimulus.instret_after,
            "pre-state and post-state alignment");
        check(observed.retired_before==retired_before && observed.retired_after==retired_ref,"independent normal-retirement count");
        check(observed==stimulus,"complete observation payload");
      end
    end
    clk_i=0;
  endtask

  /* reset all fixture sources before the first explicitly qualified capture session. */
  initial begin
    clk_i=0; capture_reset_i=0; cold_reset_i=0; isolated_i=0; hart_reset_i=0; debug_mode_i=0; debug_ebreak_entry_i=0; hold_i=0; stage_valid_i=0; transfer_i=0; in_valid_i=0; in_ready_i=0; in_packet_i=0; mip_levels_i=0; mcycle_i=0; minstret_i=0; mcountinhibit_i=0; trace_i=0; kill_valid_i=0; irq_valid_i=0; idle_i=0; fatal_i=0; irq_pc_i=0; irq_cause_i=0; fatal_record_i=0; redirect_valid_i=0; redirect_pc_i=0; flush_valid_i=0; flush_ready_i=0; flush_aborted_i=0; flush_pc_i=0; mem_launch_i=0; d_req_valid_i=0; d_req_ready_i=0; d_req_write_i=0; d_req_addr_i=0; d_req_wdata_i=0; d_req_tag_i=0; d_req_size_i=0; d_req_wstrb_i=0; d_rsp_valid_i=0; d_rsp_ready_i=0; d_rsp_tag_i=0; d_rsp_rdata_i=0; d_rsp_status_i=0; i_req_valid_i=0; i_req_ready_i=0; i_req_addr_i=0; i_req_tag_i=0; i_req_parcels_i=0; i_rsp_valid_i=0; i_rsp_ready_i=0; i_drop_i=0; i_fatal_i=0; i_fatal_reason_i=0; i_rsp_tag_i=0; i_rsp_data_i=0; i_rsp_parcels_i=0; i_rsp_fault_i=0; i_rsp_status_i=0;
    /* reset every unpacked stage and kill lane independently. */
    for (int stage=0;stage<5;stage++) begin stage_token_i[stage]='0; kill_uid_i[stage]=0; end
    if (!$value$plusargs("seed=%d",seed)) seed=1;
    rng=32'(seed)^32'hc126a7bd;
    capture_reset_i=1; cold_reset_i=1; isolated_i=1; stimulus='0; tick();
    capture_reset_i=0;
    /* enough edges reach each reduced-width limit and test its sticky invalid state. */
    repeat (40) begin populate(); tick(); end
    check(valid_records>0 && (PROFILE==0?lost_records==0:lost_records>0),"required valid and exhausted capture coverage");
    /* coincident exhaustion retains every reason without an observation-counter wrap. */
    if (PROFILE>=4) check(loss_ref==(PROFILE==4?3'b101:3'b111),"simultaneous capture exhaustion");
    /* a CPU reset alone never clears capture exhaustion. */
    populate(); cold_reset_i=1; stimulus.cold_reset=1; tick();
    check(PROFILE==0 || !record_o.valid,"CPU reset cannot repair lost observation identity");
    /* an unsafe attempt must fail the adapter's own rearm contract. */
    if ($test$plusargs("unsafe_rearm")) begin capture_reset_i=1; cold_reset_i=0; isolated_i=0; tick(); end
    capture_reset_i=1; cold_reset_i=1; isolated_i=1; stimulus='0; tick();
    capture_reset_i=0; populate(); stimulus.terminal.valid=0; tick();
    check(record_o.valid && record_o.sequence_id==1 && record_o.retired_after==0,"fresh isolated capture after overflow");
    check(!$test$plusargs("mutate_phase") && !$test$plusargs("mutate_retired") &&
        !$test$plusargs("mutate_overflow") && !$test$plusargs("unsafe_rearm"),"negative control activated");
    $display("OBSERVE_PASS profile=%0d seed=%0d edges=%0d checks=%0d valid=%0d lost=%0d width=%0d",
        PROFILE,seed,edges,checks,valid_records,lost_records,$bits(observe_t));
    $finish;
  end
endmodule
