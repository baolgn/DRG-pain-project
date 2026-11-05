/* compare machine counters with independent clock and instruction event records. */
module drg5_counters_tb;
  logic clk_i=0, reset_i=0, access_i=0;
  logic [11:0] addr_i=0;
  logic [1:0] op_i=0;
  logic [31:0] source_i=0;
  logic read_i=0, write_i=0, commit_i=0, trap_i=0;
  logic [31:0] trap_pc_i=0, trap_cause_i=0, trap_tval_i=0;
  logic mret_i=0, retire_i=0;
  logic [31:0] mip_levels_i=0;
  logic debug_mode_i=0, debug_ebreak_entry_i=0;
  logic [1:0] legal_o;
  logic [31:0] old_o [0:1], read_value_o [0:1], new_o [0:1];
  logic [31:0] mstatus_o [0:1], mtvec_o [0:1], mscratch_o [0:1], mepc_o [0:1], mcause_o [0:1], mtval_o [0:1];
  logic [31:0] mie_o [0:1], mip_o [0:1], mcountinhibit_o [0:1];
  logic [63:0] mcycle_o [0:1], minstret_o [0:1];
  wire unused_machine_state=^{mstatus_o[0],mstatus_o[1],mtvec_o[0],mtvec_o[1],mscratch_o[0],mscratch_o[1],
      mepc_o[0],mepc_o[1],mcause_o[0],mcause_o[1],mtval_o[0],mtval_o[1],mie_o[0],mie_o[1],mip_o[0],mip_o[1]};

  /* both fixed instruction alignments share identical machine-counter semantics. */
  for (genvar c=0;c<2;c++) begin : banks
    drg5_csr #(.C_ENABLED(c!=0)) bank (
      .clk_i,.reset_i,.access_i,.addr_i,.op_i,.source_i,.read_i,.write_i,.commit_i,.trap_i,
      .trap_pc_i,.trap_cause_i,.trap_tval_i,.mret_i,.retire_i,.mip_levels_i,.debug_mode_i,.debug_ebreak_entry_i,
      .legal_o(legal_o[c]),.old_o(old_o[c]),.read_value_o(read_value_o[c]),.new_o(new_o[c]),
      .mstatus_o(mstatus_o[c]),.mtvec_o(mtvec_o[c]),.mscratch_o(mscratch_o[c]),.mepc_o(mepc_o[c]),
      .mcause_o(mcause_o[c]),.mtval_o(mtval_o[c]),.mie_o(mie_o[c]),.mip_o(mip_o[c]),
      .mcountinhibit_o(mcountinhibit_o[c]),.mcycle_o(mcycle_o[c]),.minstret_o(minstret_o[c])
    );
  end

  /* event identity is independent of the bank's normalized retirement input. */
  typedef enum int {RESET_EVENT, STALL_EVENT, RETIRE32_EVENT, RETIRE16_EVENT, TRAP_EVENT,
      IRQ_EVENT, WFI_EVENT, HALT_EVENT, DEBUG_EVENT, RESUME_EVENT, STEP_EVENT,
      STEP_TRAP_EVENT, EBREAK_DEBUG_EVENT, CSR_EVENT, COLLISION_EVENT} event_t;
  event_t event_kind=RESET_EVENT;
  localparam logic [63:0] RADIX=64'h100000000;
  logic [63:0] cycle_ref=0, retire_ref=0;
  logic [31:0] inhibit_ref=5;
  logic [31:0] seed=0, rng=0;
  int edges=0, checks=0, cases=0, retirement_records=0, compressed_records=0, stall_records=0;
  int trap_records=0, irq_records=0, debug_records=0, halt_records=0, resume_records=0;
  int step_records=0, ebreak_debug_records=0, writes=0, suppressed_reads=0, suppressed_writes=0;
  int cycle_carries=0, instret_carries=0, cycle_wraps=0, instret_wraps=0;
  int inhibit_edges=0, debug_writes=0, retry_reads=0, coherent_reads=0, alias_rejects=0;
  int half_writes [0:3];
  bit mutation_applied=0;
  int ledger_file=0;
  string ledger_path;
  logic [63:0] ledger_digest=64'hcbf29ce484222325;
  logic [31:0] last_read=0;
  logic [63:0] last_read_counter=0;
  logic [63:0] history_cycle [0:15], history_retire [0:15];
  int history_event [0:15];

  /* retain the recent independent ledger at the first failing comparison. */
  task automatic check(input bit condition, input string message);
    checks++;
    /* no failing observation can update the reference state. */
    if (!condition) begin
      $display("COUNTER_CHECK_FAILED %s seed=%0d case=%0d edge=%0d event=%0d addr=%03x op=%0d source=%08x read=%b write=%b commit=%b trap=%b retire=%b debug=%b ebreak=%b",message,seed,cases,edges,event_kind,addr_i,op_i,source_i,read_i,write_i,commit_i,trap_i,retire_i,debug_mode_i,debug_ebreak_entry_i);
      /* bounded history reveals the preceding writes, freezes and rollover edges. */
      for (int n=0;n<16;n++) $display("HISTORY slot=%0d event=%0d cycle=%016x instret=%016x",n,history_event[n],history_cycle[n],history_retire[n]);
      $fatal(1,"counter event ledger mismatch");
    end
  endtask

  /* a local generator makes every service/event schedule exactly reproducible. */
  function automatic logic [31:0] random_word;
    rng=rng*32'd1664525+32'd1013904223;
    return rng;
  endfunction

  /* map tested machine-counter words without borrowing a DUT decode result. */
  function automatic int register_index(input logic [11:0] address);
    /* decimal addresses keep the independent whitelist visibly separate. */
    case (int'(address))
      2816:return 0;
      2944:return 1;
      2818:return 2;
      2946:return 3;
      800:return 4;
      /* zero HPM placeholders do not advertise event counting or Zihpm. */
      2819,2847,2947,2975,803,831:return 5;
      default:return -1;
    endcase
  endfunction

  /* each instruction record contributes zero or one, independent of its encoded length. */
  function automatic bit record_retires(input event_t kind);
    return kind inside {RETIRE32_EVENT,RETIRE16_EVENT,WFI_EVENT,STEP_EVENT,CSR_EVENT};
  endfunction

  /* clear event controls without altering counter state or the fixture's ledger. */
  task automatic clear_controls;
    reset_i=0; access_i=0; addr_i=0; op_i=0; source_i=0; read_i=0; write_i=0; commit_i=0;
    trap_i=0; trap_pc_i=0; trap_cause_i=0; trap_tval_i=0; mret_i=0; retire_i=0;
    debug_mode_i=0; debug_ebreak_entry_i=0;
  endtask

  /* construct one external execution/debug record and its public bank signals. */
  task automatic select_event(input event_t kind);
    clear_controls(); event_kind=kind; retire_i=record_retires(kind);
    reset_i=kind==RESET_EVENT;
    trap_i=kind inside {TRAP_EVENT,IRQ_EVENT,STEP_TRAP_EVENT};
    trap_cause_i=kind==IRQ_EVENT?32'h8000000b:32'd2;
    debug_mode_i=kind inside {DEBUG_EVENT,RESUME_EVENT};
    debug_ebreak_entry_i=kind==EBREAK_DEBUG_EVENT;
  endtask

  /* compare pre-edge reads and independently advance full-width event totals. */
  task automatic tick;
    int index;
    bit legal, write_commits, add_cycle, add_instret, blocked_debug;
    logic [31:0] old_value, written, observed_read;
    logic [63:0] next_cycle, next_retire, observed_cycle, observed_retire;
    logic [31:0] next_inhibit;
    #1; index=register_index(addr_i); legal=access_i && index>=0; old_value=0;
    /* word selection uses arithmetic division and remainder rather than DUT slices. */
    case (index)
      0:old_value=32'(cycle_ref%RADIX);
      1:old_value=32'(cycle_ref/RADIX);
      2:old_value=32'(retire_ref%RADIX);
      3:old_value=32'(retire_ref/RADIX);
      4:old_value=inhibit_ref;
      default:old_value=0;
    endcase
    written=old_value;
    /* normalized read/write controls independently describe the six encoded CSR forms. */
    if (write_i) begin
      /* every source bit participates in replacement, set or clear independently. */
      for (int b=0;b<32;b++) begin
        case (op_i)
          1:written[b]=source_i[b];
          2:written[b]=source_i[b]?1'b1:old_value[b];
          3:written[b]=source_i[b]?1'b0:old_value[b];
          default:written[b]=old_value[b];
        endcase
      end
    end
    /* inhibit has only CY/IR, and implemented HPM placeholders remain constant. */
    if (index==4) written=(written[0]?32'd1:0)+(written[2]?32'd4:0);
    else if (index==5) written=0;
    last_read=legal && read_i?old_value:0;
    last_read_counter=index<2?cycle_ref:retire_ref;
    /* all preview observations precede this instruction's own clock/retirement update. */
    for (int profile=0;profile<2;profile++) begin
      observed_read=read_value_o[profile];
      /* a fabricated value on a suppressed read must fail its ordinary comparator. */
      if ($test$plusargs("mutate_suppression") && legal && !read_i && !mutation_applied) begin observed_read^=1; mutation_applied=1; end
      check(legal_o[profile]==legal,"counter address permission");
      check(old_o[profile]==(legal?old_value:0) && new_o[profile]==(legal?written:0),"counter pre-edge preview");
      check(observed_read==last_read,"suppressed or pre-retirement read");
    end
    blocked_debug=debug_mode_i || debug_ebreak_entry_i;
    add_cycle=!reset_i && !blocked_debug && !inhibit_ref[0];
    add_instret=!reset_i && !blocked_debug && !trap_i && retire_i && !inhibit_ref[2];
    write_commits=!reset_i && !trap_i && !mret_i && commit_i && legal && write_i;
    next_cycle=cycle_ref+64'(add_cycle); next_retire=retire_ref+64'(add_instret); next_inhibit=inhibit_ref;
    /* an explicit write is an event that replaces a word in the pre-edge counter. */
    if (write_commits) begin
      case (index)
        0:next_cycle=(cycle_ref/RADIX)*RADIX+64'(written);
        1:next_cycle=64'(written)*RADIX+(cycle_ref%RADIX);
        2:next_retire=(retire_ref/RADIX)*RADIX+64'(written);
        3:next_retire=64'(written)*RADIX+(retire_ref%RADIX);
        4:next_inhibit=written;
        default:begin end
      endcase
    end
    /* reset erases both counts and inhibits further increments regardless of other events. */
    if (reset_i) begin next_cycle=0; next_retire=0; next_inhibit=5; end
    clk_i=1; #2; edges++;
    /* a detector changes only the observed result; it cannot contaminate the event ledger. */
    for (int profile=0;profile<2;profile++) begin
      observed_cycle=mcycle_o[profile]; observed_retire=minstret_o[profile];
      /* a lost carry must fail a directed low-word rollover. */
      if ($test$plusargs("mutate_carry") && add_cycle && !write_commits && cycle_ref%RADIX==RADIX-1 && !mutation_applied) begin
        observed_cycle-=RADIX; mutation_applied=1;
      end
      /* a clock increment during Debug Mode must be detected independently of retirement. */
      if ($test$plusargs("mutate_debug") && debug_mode_i && !reset_i && !write_commits && !mutation_applied) begin
        observed_cycle++; mutation_applied=1;
      end
      /* trapped instructions cannot acquire an ordinary retirement count. */
      if ($test$plusargs("mutate_trap") && trap_i && !reset_i && !mutation_applied) begin
        observed_retire++; mutation_applied=1;
      end
      /* counter writes suppress their own implicit update across both words. */
      if ($test$plusargs("mutate_write") && write_commits && index==2 && !inhibit_ref[2] && !mutation_applied) begin
        observed_retire++; mutation_applied=1;
      end
      check(observed_cycle==next_cycle,"cycle ledger");
      check(observed_retire==next_retire,"retirement ledger");
      check(mcountinhibit_o[profile]==next_inhibit,"inhibition ledger");
    end
    /* coverage records the input schedule, not an inferred DUT operation. */
    if (!reset_i) begin
      retirement_records+=int'(record_retires(event_kind)); compressed_records+=int'(event_kind==RETIRE16_EVENT);
      stall_records+=int'(event_kind==STALL_EVENT); trap_records+=int'(event_kind inside {TRAP_EVENT,STEP_TRAP_EVENT});
      irq_records+=int'(event_kind==IRQ_EVENT); debug_records+=int'(debug_mode_i); halt_records+=int'(event_kind==HALT_EVENT);
      resume_records+=int'(event_kind==RESUME_EVENT); step_records+=int'(event_kind==STEP_EVENT);
      ebreak_debug_records+=int'(debug_ebreak_entry_i); inhibit_edges+=int'(inhibit_ref!=0);
      suppressed_reads+=int'(legal && !read_i); suppressed_writes+=int'(legal && !write_i);
      alias_rejects+=int'(access_i && index<0);
      /* only genuine automatic carry/wrap events count as rollover coverage. */
      if (add_cycle && !(write_commits && index inside {0,1})) begin
        cycle_carries+=int'(cycle_ref%RADIX==RADIX-1); cycle_wraps+=int'(cycle_ref=='1);
      end
      /* a low/high minstret write defeats rollover for the entire counter. */
      if (add_instret && !(write_commits && index inside {2,3})) begin
        instret_carries+=int'(retire_ref%RADIX==RADIX-1); instret_wraps+=int'(retire_ref=='1);
      end
      /* high/low writes and debug abstract writes need actual committed coverage. */
      if (write_commits) begin
        writes++; debug_writes+=int'(debug_mode_i);
        /* only four actual counter words contribute to this coverage vector. */
        if (index<4) half_writes[index]++;
      end
    end
    cycle_ref=next_cycle; retire_ref=next_retire; inhibit_ref=next_inhibit;
    ledger_digest=(ledger_digest^cycle_ref)*64'h100000001b3;
    ledger_digest=(ledger_digest^retire_ref^64'(event_kind))*64'h100000001b3;
    history_cycle[edges%16]=cycle_ref; history_retire[edges%16]=retire_ref; history_event[edges%16]=int'(event_kind);
    /* optional full edge records preserve independently derived values and raw bank events. */
    if (ledger_file!=0) $fdisplay(ledger_file,"%0d,%0d,%03x,%0d,%08x,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%016x,%016x,%08x,%016x,%016x",
        edges,event_kind,addr_i,op_i,source_i,reset_i,access_i,read_i,write_i,commit_i,trap_i,mret_i,retire_i,
        debug_mode_i,debug_ebreak_entry_i,cycle_ref,retire_ref,inhibit_ref,mcycle_o[0],minstret_o[0]);
    clk_i=0;
  endtask

  /* choose encoded CSR read/write suppression from indices, not source register values. */
  task automatic csr_form(input logic [11:0] address, input int form, source_index, destination,
      input logic [31:0] register_value);
    select_event(CSR_EVENT); access_i=1; addr_i=address; op_i=2'(form%4);
    source_i=form>=4?32'(source_index):source_index==0?32'b0:register_value;
    read_i=(form%4)!=1 || destination!=0;
    write_i=(form%4)==1 || source_index!=0; commit_i=1;
    /* rejected architectural CSR probes trap instead of claiming a retirement. */
    if (register_index(address)<0) begin
      event_kind=TRAP_EVENT; retire_i=0; trap_i=1; trap_cause_i=2;
    end
    tick();
  endtask

  /* a helper writes the selected counter word through an actual retiring CSR operation. */
  task automatic write_word(input logic [11:0] address, input logic [31:0] value);
    csr_form(address,1,1,0,value);
  endtask

  /* preload both counters while inhibited so rollover starts at an exact known value. */
  task automatic preload(input logic [63:0] cycle_value, retired_value);
    write_word(12'h320,5); write_word(12'hb80,32'(cycle_value/RADIX)); write_word(12'hb00,32'(cycle_value%RADIX));
    write_word(12'hb82,32'(retired_value/RADIX)); write_word(12'hb02,32'(retired_value%RADIX));
    write_word(12'h320,0);
  endtask

  /* coherent RV32 reads retry if a low-word rollover changes either sampled high word. */
  task automatic coherent_read(input bit instruction_counter, force_retry);
    logic [31:0] high1, low, high2;
    logic [63:0] sampled;
    logic [11:0] hi_address, lo_address;
    int attempts;
    hi_address=instruction_counter?12'hb82:12'hb80; lo_address=instruction_counter?12'hb02:12'hb00;
    attempts=0;
    /* force one rollover across the three independently sampled CSR instructions. */
    if (force_retry) preload(64'h0000000afffffffe,64'h00000012fffffffe);
    high1=0; high2=1;
    /* no latch or inhibition hides a rollover from the software retry algorithm. */
    while (high1!=high2 && attempts<4) begin
      csr_form(hi_address,2,0,1,0); high1=last_read;
      csr_form(lo_address,2,0,1,0); low=last_read; sampled=last_read_counter;
      csr_form(hi_address,2,0,1,0); high2=last_read; attempts++;
      /* a mismatched high word requires a complete new three-read attempt. */
      if (high1!=high2) retry_reads++;
    end
    check(high1==high2 && {high2,low}==sampled,"coherent high-low-high read"); coherent_reads++;
    check(!force_retry || attempts>=2,"forced read rollover retries");
  endtask

  /* directed edge records supplement a reproducible mixed-control corpus. */
  initial begin
    /* initialize only the independent model and failure history before architectural reset. */
    for (int n=0;n<16;n++) begin history_cycle[n]=0; history_retire[n]=0; history_event[n]=0; end
    /* each half-write counter starts from a known diagnostic value. */
    for (int n=0;n<4;n++) half_writes[n]=0;
    if (!$value$plusargs("seed=%d",seed)) seed=1;
    /* full CSV capture is optional for direct reruns and required by the qualification runner. */
    if ($value$plusargs("ledger=%s",ledger_path)) begin
      ledger_file=$fopen(ledger_path,"w"); check(ledger_file!=0,"open event ledger");
      $fdisplay(ledger_file,"edge,event,addr,op,source,reset,access,read,write,commit,trap,mret,retire,debug,debug_ebreak,expected_cycle,expected_instret,inhibit,observed_cycle,observed_instret");
    end
    rng=seed; select_event(RESET_EVENT); tick(); cases++;
    /* enabled counters count stalled clocks but only actual instruction-retirement records. */
    write_word(12'h320,0);
    /* no instruction retires during these useful-work stalls. */
    repeat (9) begin select_event(STALL_EVENT); tick(); end
    select_event(RETIRE32_EVENT); tick(); select_event(RETIRE16_EVENT); tick();
    select_event(TRAP_EVENT); tick(); select_event(IRQ_EVENT); tick(); select_event(WFI_EVENT); tick();
    /* WFI idle clocks count independently of instruction retirement. */
    repeat (7) begin select_event(STALL_EVENT); tick(); end
    /* ordinary halt/step entry counts; pre-existing Debug Mode and resume edges do not. */
    select_event(HALT_EVENT); tick();
    /* fixed stopcount freezes both counters throughout these halted edges. */
    repeat (7) begin select_event(DEBUG_EVENT); tick(); end
    select_event(RESUME_EVENT); tick(); select_event(STEP_EVENT); tick(); select_event(DEBUG_EVENT); tick();
    select_event(RESUME_EVENT); tick(); select_event(STEP_TRAP_EVENT); tick(); select_event(DEBUG_EVENT); tick();
    select_event(RESUME_EVENT); tick(); select_event(EBREAK_DEBUG_EVENT); tick();
    select_event(DEBUG_EVENT); tick(); cases++;
    /* explicit debugger writes remain legal while fixed stopcount freezes automatic increments. */
    for (int word_index=0;word_index<4;word_index++) begin
      select_event(DEBUG_EVENT); access_i=1; commit_i=1; read_i=1; write_i=1; op_i=1;
      addr_i=word_index==0?12'hb00:word_index==1?12'hb80:word_index==2?12'hb02:12'hb82;
      source_i=32'h12345670+32'(word_index); tick();
    end
    /* writes win over low carry and full-width wrap for either selected half. */
    preload(64'hffffffffffffffff,64'hffffffffffffffff); select_event(RETIRE16_EVENT); tick(); cases++;
    preload(64'h00000000ffffffff,64'h00000000ffffffff); select_event(RETIRE32_EVENT); tick();
    preload(64'h00000005ffffffff,64'h00000007ffffffff); write_word(12'hb80,17); write_word(12'hb82,19);
    preload(64'hffffffffffffffff,64'hffffffffffffffff); write_word(12'hb00,123); write_word(12'hb02,456);
    /* each half-write individually defeats a pending full-width rollover. */
    for (int word_index=0;word_index<4;word_index++) begin
      preload(64'hffffffffffffffff,64'hffffffffffffffff);
      addr_i=word_index==0?12'hb00:word_index==1?12'hb80:word_index==2?12'hb02:12'hb82;
      write_word(addr_i,32'h81a50000+32'(word_index));
    end
    /* pre-edge inhibition determines both counter updates on the writing instruction itself. */
    for (int combination=0;combination<4;combination++) begin
      write_word(12'h320,32'((combination&1)|((combination&2)<<1)));
      select_event(RETIRE16_EVENT); tick(); select_event(STALL_EVENT); tick();
    end
    coherent_read(0,1); coherent_read(1,1); coherent_read(0,0); coherent_read(1,0); cases++;
    /* all six CSR forms distinguish x0 selection from a nonzero source holding zero. */
    for (int form=1;form<8;form++) begin
      /* funct3 four is reserved; all six specified forms remain covered. */
      if (form!=4) begin
        /* all counter words and inhibit have independent access/control combinations. */
        for (int word_index=0;word_index<5;word_index++) begin
          addr_i=word_index==0?12'hb00:word_index==1?12'hb80:word_index==2?12'hb02:word_index==3?12'hb82:12'h320;
          /* zero/nonzero source identities and rd identities cover read/write suppression. */
          for (int indices=0;indices<4;indices++) begin
            csr_form(addr_i,form,indices[0]?1:0,indices[1]?1:0,0);
            csr_form(addr_i,form,indices[0]?31:0,indices[1]?31:0,32'hf0a5c30f);
          end
        end
      end
    end
    /* aliases and lower-mode controls remain absent even on otherwise suppressed accesses. */
    for (int alias_index=0;alias_index<8;alias_index++) begin
      case (alias_index)
        0:addr_i=12'hc00; 1:addr_i=12'hc01; 2:addr_i=12'hc02; 3:addr_i=12'hc80;
        4:addr_i=12'hc81; 5:addr_i=12'hc82; 6:addr_i=12'h306; default:addr_i=12'h321;
      endcase
      csr_form(addr_i,2,0,1,0); csr_form(addr_i,1,0,0,0);
    end
    /* all reset/trap/return/commit/debug collision combinations have explicit event outcomes. */
    for (int collision=0;collision<128;collision++) begin
      preload(64'h00000011ffffffff,64'h00000019ffffffff);
      select_event(COLLISION_EVENT); access_i=1; addr_i=collision[0]?12'hb00:12'hb82;
      op_i=1; source_i=32'hcafebabe; write_i=1; read_i=1;
      {reset_i,trap_i,mret_i,commit_i,retire_i,debug_mode_i,debug_ebreak_entry_i}=7'(collision);
      trap_cause_i=11; tick();
    end
    /* random data, independent controls and alias probes exercise every ordering combination. */
    for (int sample=0;sample<20000;sample++) begin
      select_event(COLLISION_EVENT); source_i=random_word();
      case (random_word()%12)
        0:addr_i=12'hb00; 1:addr_i=12'hb80; 2:addr_i=12'hb02; 3:addr_i=12'hb82; 4:addr_i=12'h320;
        5:addr_i=12'hb03; 6:addr_i=12'hb9f; 7:addr_i=12'h323; 8:addr_i=12'hc00;
        9:addr_i=12'hc82; 10:addr_i=12'h306; default:addr_i=12'h321;
      endcase
      {reset_i,access_i,read_i,write_i,commit_i,trap_i,mret_i,retire_i,debug_mode_i,debug_ebreak_entry_i}=10'(random_word());
      op_i=2'(random_word()); trap_cause_i=32'(sample%8); tick();
    end
    check(cycle_carries>0 && instret_carries>0 && cycle_wraps>0 && instret_wraps>0,"directed rollover coverage");
    check(compressed_records>0 && stall_records>0 && trap_records>0 && irq_records>0 && debug_records>0 &&
        halt_records>0 && resume_records>0 && step_records>0 && ebreak_debug_records>0 && debug_writes>=4,"execution and debug event coverage");
    check(retry_reads>=2 && coherent_reads==4 && suppressed_reads>0 && suppressed_writes>0 && alias_rejects>0,"RV32 access coverage");
    /* every machine counter half must receive a successful write. */
    for (int n=0;n<4;n++) check(half_writes[n]>0,"half-write coverage");
    check(!$test$plusargs("mutate_carry") && !$test$plusargs("mutate_debug") && !$test$plusargs("mutate_trap") &&
        !$test$plusargs("mutate_write") && !$test$plusargs("mutate_suppression"),"selected detector activated");
    $display("COUNTERS_PASS seed=%0d profiles=2 cases=%0d edges=%0d checks=%0d records=%0d compressed=%0d stalls=%0d traps=%0d irqs=%0d debug=%0d halt=%0d resume=%0d step=%0d ebreak_debug=%0d writes=%0d debug_writes=%0d cycle_carries=%0d instret_carries=%0d cycle_wraps=%0d instret_wraps=%0d retries=%0d coherent_reads=%0d aliases=%0d ledger=%016x",
        seed,cases,edges,checks,retirement_records,compressed_records,stall_records,trap_records,irq_records,
        debug_records,halt_records,resume_records,step_records,ebreak_debug_records,writes,debug_writes,
        cycle_carries,instret_carries,cycle_wraps,instret_wraps,retry_reads,coherent_reads,alias_rejects,ledger_digest);
    /* close the full event record only after every required check succeeds. */
    if (ledger_file!=0) $fclose(ledger_file);
    $finish;
  end
endmodule
