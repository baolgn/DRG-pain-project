/* check FENCE.I ownership at asynchronous entry, flush and reset boundaries. */
module drg5_fence_events_tb #(parameter bit C_ENABLED = 0);
  import drg5_control_pkg::*;
  logic clk_i = 0, cold_reset_i = 0, isolated_i = 1, hart_reset_i = 0;
  logic [4:0] hold_i = 0;
  logic in_valid_i = 0, in_ready_o;
  packet_t in_packet_i = '0;
  logic flush_valid_i = 0, flush_ready_o, flush_aborted_o;
  logic [31:0] flush_pc_i = 0;
  logic redirect_valid_o;
  logic [31:0] redirect_pc_o;
  logic d_req_valid_o, d_req_ready_i = 0, d_req_write_o;
  logic [31:0] d_req_addr_o, d_req_wdata_o, d_req_tag_o;
  logic [1:0] d_req_size_o;
  logic [3:0] d_req_wstrb_o;
  logic d_rsp_valid_i = 0, d_rsp_ready_o;
  logic [31:0] d_rsp_tag_i = 0, d_rsp_rdata_i = 0;
  logic [1:0] d_rsp_status_i = 0;
  logic mem_launch_o, mem_busy_o, fatal_o;
  fatal_record_t fatal_record_o;
  logic [4:0] stage_valid_o, kill_valid_o;
  token_t stage_token_o [0:4];
  logic [3:0] transfer_o;
  logic [63:0] kill_uid_o [0:4];
  trace_t trace_o;
  logic [4:0] inspect_reg_i = 0;
  logic [31:0] inspect_value_o;
  logic inspect_defined_o;
  logic [31:0] mstatus_o, mtvec_o, mscratch_o, mepc_o, mcause_o, mtval_o;
  /* counters remain observable without affecting event scheduling. */
  logic [31:0] mie_o, mip_o, mcountinhibit_o;
  logic [63:0] mcycle_o, minstret_o;


  logic [31:0] mip_levels_i = 0;
  logic fetch_busy_i = 0, entry_pending_o, idle_o, irq_valid_o;
  logic [31:0] irq_pc_o, irq_cause_o;
  wire unused_observation = ^{isolated_i, d_req_addr_o, d_req_wdata_o, d_req_tag_o,
      d_req_write_o, d_req_size_o, d_req_wstrb_o, d_rsp_ready_o, fatal_record_o,
      transfer_o, inspect_value_o, inspect_defined_o, mstatus_o, mtvec_o, mscratch_o,
      mie_o, mip_o, mcountinhibit_o, mcycle_o, minstret_o, flush_aborted_o,
      entry_pending_o, idle_o, mem_busy_o};
  bit live [0:63];
  int next_uid=0, order_ref=0, cases=0, cycles=0, checks=0;
  int retired=0, traps=0, fence_count=0, kills=0, resets=0, irqs=0, redirects=0;
  int irq_before=0, irq_after=0, flush_cases=0, reset_cases=0, older_faults=0, base_rejects=0;
  logic [31:0] fence_pc=0;
  bit expect_trap=0;
  logic [31:0] expected_cause=0, expected_tval=0, expected_epc=0;
  localparam logic [31:0] FENCE_BITS=32'hffff9f8f;

  /* raw FENCE.I uses production decode; synthetic CSR packets only arrange machine state. */
  drg5_control #(.C_ENABLED(C_ENABLED), .ZIFENCEI_ENABLED(1), .IRQ_ENABLED(1),
      .DIAGNOSTIC(0), .FORWARDING(1)) dut (.*);

  /* fail immediately with reproducible case and stage context. */
  task automatic check(input bit condition, input string message);
    checks++;
    /* a failed assertion preserves the event boundary before another edge. */
    if (!condition) $fatal(1,"FENCE_EVENT_FAIL C=%0d case=%0d cycle=%0d stages=%05b: %s",
        C_ENABLED,cases,cycles,stage_valid_o,message);
  endtask

  /* ignore supplied execution annotations when decoding a real fence instruction. */
  function automatic packet_t fence_packet(input logic [31:0] pc, input op_t op=OP_MACHINE);
    packet_t p;
    p='0; p.pc=pc; p.raw=FENCE_BITS; p.raw_valid=15; p.length=4; p.op=op;
    p.rs1_used=1; p.rs2_used=1; p.rs1=31; p.rs2=30; p.rd=29; p.rd_write=1;
    p.rs1_value='hbad; p.rs2_value='hbad; p.result='hdeadbeef; p.next_pc='hbad;
    return p;
  endfunction

  /* each clock independently accounts input, terminal, kill and reset ownership. */
  task automatic tick;
    bit accepted, reset_edge;
    logic [4:0] old_valid;
    int count, id;
    accepted=in_valid_i && in_ready_o; reset_edge=cold_reset_i || hart_reset_i;
    old_valid=stage_valid_o;
    #2; clk_i=1; #2; clk_i=0; cycles++;
    check(!fatal_o && !d_req_valid_o && !mem_launch_o,"event-only instructions cannot launch data accesses");
    /* reset aborts all instructions without a retirement or interrupt entry. */
    if (reset_edge) begin
      check(!trace_o.valid && !irq_valid_o && stage_valid_o==0,"reset suppresses architectural events");
      /* reset identity reuse is allowed only after every old token is explicitly aborted. */
      for (int n=0;n<64;n++) live[n]=0;
      kills+=$countones(old_valid); next_uid=0; order_ref=0; resets++;
    end
    /* normal edges conserve accepted identities across terminals and kills. */
    else begin
      /* the test producer assigns identities independently of observed DUT UIDs. */
      if (accepted) begin
        check(next_uid<64,"bounded stimulus identity"); live[next_uid]=1; next_uid++;
      end
      /* killed identities cannot later appear as architectural dispositions. */
      for (int stage=0;stage<5;stage++) begin
        if (kill_valid_o[stage]) begin
          id=int'(kill_uid_o[stage]); check(id<next_uid && live[id],"one kill per live owner");
          live[id]=0; kills++;
        end
      end
      /* every terminal consumes exactly one owner in monotonic retirement order. */
      if (trace_o.valid) begin
        id=int'(trace_o.uid); check(id<next_uid && live[id],"one terminal per live owner");
        check(trace_o.order==64'(order_ref),"retirement order");
        live[id]=0; order_ref++;
        /* fault metadata comes from the selected stimulus, not the observed decode. */
        if (trace_o.trap) begin
          check(expect_trap && trace_o.packet.cause==expected_cause && trace_o.packet.mtval==expected_tval &&
              mepc_o==expected_epc && mcause_o==expected_cause && mtval_o==expected_tval,
              "precise synchronous trap wins");
          check(!trace_o.rd_write && !trace_o.csr_write,"fault suppresses normal architectural writes");
          traps++; expect_trap=0;
        end
        /* a real fence creates one continuation and no GPR or CSR effect. */
        else if (trace_o.packet.raw==FENCE_BITS) begin
          check(trace_o.packet.op==OP_FENCE_I && trace_o.packet.pc==fence_pc &&
              trace_o.packet.length==4 && trace_o.packet.raw_valid==15,"original fence identity");
          check(!trace_o.packet.rs1_used && !trace_o.packet.rs2_used && !trace_o.rd_write &&
              !trace_o.csr_read && !trace_o.csr_write,"ignored fields cannot become effects or dependencies");
          check(redirect_valid_o && redirect_pc_o==fence_pc+4 && trace_o.next_pc==fence_pc+4,
              "one ordered fence continuation"); fence_count++; retired++;
        end
        /* only explicit setup CSR writes may otherwise retire in this fixture. */
        else begin
          check(trace_o.packet.op==OP_CSR && trace_o.csr_write && !trace_o.rd_write,"setup CSR disposition");
          retired++;
        end
      end
      /* interrupt entry is an instruction boundary, never a second terminal. */
      if (irq_valid_o) begin
        check(!trace_o.valid && irq_cause_o==32'h8000000b && mcause_o==irq_cause_o &&
            mepc_o==irq_pc_o && mtval_o==0 && redirect_pc_o==32'h100,"precise external interrupt entry");
        irqs++;
      end
      /* stale tokens must not survive a terminal redirect or a kill. */
      for (int uid=0;uid<next_uid;uid++) begin
        count=0;
        /* independently count every possible stage owner of this input identity. */
        for (int stage=0;stage<5;stage++) count+=int'(stage_valid_o[stage] && stage_token_o[stage].uid==64'(uid));
        check(count==int'(live[uid]),"instruction conservation");
      end
    end
    /* registered redirects are observed once per actual output edge. */
    if (redirect_valid_o) redirects++;
  endtask

  /* reset with no external bus owner starts each independently reproducible scenario. */
  task automatic fresh;
    cases++; hold_i=0; in_valid_i=0; flush_valid_i=0; mip_levels_i=0; fetch_busy_i=0;
    hart_reset_i=0; cold_reset_i=1; expect_trap=0; tick(); cold_reset_i=0; tick(); tick();
  endtask

  /* a producer waits for actual input acceptance and never drops a pending packet. */
  task automatic send(input packet_t p);
    int wait_edges;
    in_packet_i=p; in_valid_i=1; #1; wait_edges=0;
    /* bounded readiness exposes deadlock without assuming a fixed pipeline latency. */
    while (!in_ready_o && wait_edges<40) begin tick(); wait_edges++; end
    check(in_ready_o,"input acceptance deadline"); tick(); in_valid_i=0;
  endtask

  /* observe a selected stage without overriding private core state. */
  task automatic await_stage(input int stage);
    int wait_edges;
    wait_edges=0;
    /* all stage progression remains driven by public packet and hold interfaces. */
    while (!stage_valid_o[stage] && wait_edges<40) begin tick(); wait_edges++; end
    check(stage_valid_o[stage],"stage arrival deadline");
  endtask

  /* machine-state setup uses explicit diagnostic CSR intent and checked retirement. */
  task automatic csr_write(input logic [31:0] pc, input logic [11:0] address, input logic [31:0] value);
    packet_t p;
    int before_retired, wait_edges;
    p='0; p.pc=pc; p.raw='h13; p.raw_valid=15; p.length=4; p.op=OP_CSR; p.next_pc=pc+4;
    p.csr_addr=address; p.csr_op=CSR_WRITE; p.csr_write=1; p.csr_source=value;
    before_retired=retired; wait_edges=0; send(p);
    /* no following setup step may infer completion from preparation alone. */
    while (retired==before_retired && wait_edges<40) begin tick(); wait_edges++; end
    check(retired==before_retired+1,"setup CSR retirement deadline");
  endtask

  /* enable only machine external interrupts and choose a stable direct vector. */
  task automatic enable_irq;
    csr_write(0,12'h305,32'h100); csr_write(4,12'h304,32'h800); csr_write(8,12'h300,32'h8);
  endtask

  /* reset or flush may abort an unretired fence in any stage, including prepared W. */
  task automatic abort_fence(input int stage, input bit reset_hart, prepared);
    int before_fences, before_irqs, before_redirects;
    fresh(); fence_pc=C_ENABLED?2:0; before_fences=fence_count; before_irqs=irqs;
    hold_i=5'b1<<stage; send(fence_packet(fence_pc)); await_stage(stage);
    /* W preparation is not retirement and creates no irrevocable memory side effect. */
    if (prepared) begin
      hold_i=0; tick(); check(stage_token_o[4].serial_ready && !trace_o.valid,"fence prepared once"); hold_i[4]=1;
    end
    repeat (3) tick(); before_redirects=redirects;
    /* architectural reset overrides preparation and every proposed redirect. */
    if (reset_hart) begin hart_reset_i=1; tick(); hart_reset_i=0; reset_cases++; end
    /* a public flush terminates the fence and supplies its own continuation. */
    else begin
      flush_pc_i=32'h200; flush_valid_i=1; check(flush_ready_o,"flush admission"); tick(); flush_valid_i=0;
      check(redirect_valid_o && redirect_pc_o==32'h200,"external flush continuation"); flush_cases++;
    end
    hold_i=0; repeat (5) tick();
    check(fence_count==before_fences && irqs==before_irqs,"aborted fence never retires or enters IRQ");
    check(redirects==before_redirects+(reset_hart?0:1),"no late or repeated fence redirect");
  endtask

  /* a pending event may preempt an unadmitted W fence before it synchronizes instructions. */
  task automatic interrupt_before;
    int before_fences, before_irqs;
    fresh(); enable_irq(); fence_pc=12; before_fences=fence_count; before_irqs=irqs;
    hold_i[4]=1; send(fence_packet(fence_pc)); await_stage(4);
    check(!stage_token_o[4].admitted && !stage_token_o[4].serial_ready,"fence remains unadmitted");
    mip_levels_i=32'h800; tick();
    check(irqs==before_irqs+1 && irq_pc_o==12 && fence_count==before_fences,"IRQ precedes unadmitted fence");
    hold_i=0; repeat (5) tick(); check(fence_count==before_fences,"preempted fence stays killed"); irq_before++;
  endtask

  /* admitted fences finish once before IRQ entry; old fetch ownership delays entry separately. */
  task automatic interrupt_after;
    int before_fences, before_irqs;
    fresh(); enable_irq(); fence_pc=12; before_fences=fence_count; before_irqs=irqs;
    hold_i[4]=1; send(fence_packet(fence_pc)); await_stage(4);
    hold_i=0; tick(); check(stage_token_o[4].admitted && stage_token_o[4].serial_ready,"W fence admission");
    fetch_busy_i=1; mip_levels_i=32'h800; hold_i[4]=1; repeat (5) tick();
    check(fence_count==before_fences && irqs==before_irqs,"held admitted fence blocks entry");
    hold_i=0; tick(); check(fence_count==before_fences+1 && irqs==before_irqs,"fence retires before pending IRQ");
    repeat (4) tick(); check(irqs==before_irqs,"old fetch ownership blocks IRQ entry");
    fetch_busy_i=0; tick(); check(irqs==before_irqs+1 && irq_pc_o==16,"IRQ saves post-fence continuation");
    repeat (5) tick(); check(fence_count==before_fences+1,"no repeated synchronization after IRQ"); irq_after++;
  endtask

  /* an older carried fault kills the younger fence before its preparation or redirect. */
  task automatic older_fault;
    packet_t p;
    int before_fences;
    fresh(); before_fences=fence_count; hold_i[4]=1;
    p='0; p.op=OP_RESULT; p.raw='h13; p.raw_valid=15; p.length=4; p.fault=1;
    p.cause=5; p.mtval=32'h20000000; p.pc=0;
    expect_trap=1; expected_cause=5; expected_tval=p.mtval; expected_epc=0;
    send(p); await_stage(4); fence_pc=4; send(fence_packet(fence_pc)); repeat (2) tick();
    hold_i=0; tick(); check(!expect_trap && fence_count==before_fences,"older exception priority");
    repeat (6) tick(); check(fence_count==before_fences,"killed fence has no late effect"); older_faults++;
  endtask

  /* OP_BASE rejects FENCE.I even when the separate machine interface enables it. */
  task automatic base_only;
    int before_traps, wait_edges;
    fresh(); before_traps=traps; wait_edges=0; expect_trap=1;
    expected_cause=2; expected_tval=0; expected_epc=0; send(fence_packet(0,OP_BASE));
    /* base-only legality is checked at its precise terminal boundary. */
    while (traps==before_traps && wait_edges<40) begin tick(); wait_edges++; end
    check(traps==before_traps+1,"base entry rejects FENCE.I"); base_rejects++;
  endtask

  /* run both event dispositions at every reachable stage and preparation boundary. */
  initial begin
    /* the independent live ledger begins empty before the first qualified reset. */
    for (int n=0;n<64;n++) live[n]=0;
    for (int stage=0;stage<5;stage++) begin abort_fence(stage,0,0); abort_fence(stage,1,0); end
    abort_fence(4,0,1); abort_fence(4,1,1);
    interrupt_before(); interrupt_after(); older_fault(); base_only();
    check(flush_cases==6 && reset_cases==6 && irq_before==1 && irq_after==1 && older_faults==1 && base_rejects==1,
        "complete event coverage");
    $display("FENCE_EVENTS_PASS C=%0d cases=%0d checks=%0d cycles=%0d retired=%0d fences=%0d traps=%0d kills=%0d irqs=%0d flush_cases=%0d reset_cases=%0d irq_before=%0d irq_after=%0d older_faults=%0d base_rejects=%0d",
        C_ENABLED,cases,checks,cycles,retired,fence_count,traps,kills,irqs,flush_cases,reset_cases,irq_before,irq_after,older_faults,base_rejects);
    $finish;
  end
endmodule
