/* retain acquisition commands, configuration and fault evidence independently of CPU service. */
module drg5_acquisition_control #(
  parameter integer CONFIG_CYCLES = 239976000,
  parameter integer CANCEL_CYCLES = 1119,
  parameter integer CLOSE_CYCLES = 799920,
  parameter logic [63:0] COUNTER_LIMIT = 64'hffffffffffffffff
) (
  input logic clk_i, system_reset_i, cpu_reset_i, cpu_halt_i,
  input logic req_valid_i,
  output logic req_ready_o,
  input logic req_write_i,
  input logic [11:0] req_addr_i,
  input logic [31:0] req_wdata_i, req_tag_i,
  input logic [3:0] req_wstrb_i,
  output logic rsp_valid_o,
  input logic rsp_ready_i,
  output logic [31:0] rsp_rdata_o, rsp_tag_o,
  output logic rsp_error_o,
  input logic session_verified_i,
  input logic [127:0] session_id_i,
  input logic qualification_valid_i,
  input logic [63:0] qualification_config_id_i,
  input logic [255:0] qualification_digest_i,
  input logic [63:0] qualification_timebase_id_i,
  input logic [31:0] qualification_manifest_length_i,
  input logic physical_ready_i, metadata_archived_i, ownership_clear_i, pins_idle_i, arm_ready_i,
  input logic [6:0] free_blocks_i,
  input logic emergency_stop_i,
  input logic [31:0] fault_i,
  input logic supervisor_fault_i,
  input logic backend_valid_i, backend_ok_i,
  input logic [1:0] backend_phase_i,
  input logic [63:0] backend_command_id_i,
  output logic service_valid_o, service_cancel_o,
  output logic [1:0] service_phase_o,
  output logic [63:0] service_command_id_o,
  output logic [767:0] service_config_o,
  input logic close_valid_i,
  input logic [63:0] close_epoch_i,
  input logic [1:0] close_result_i,
  output logic close_request_o, terminal_sealed_o,
  output logic [63:0] epoch_o, first_tick_o,
  output logic [63:0] tick_o, arm_commit_epoch_o, arm_commit_first_tick_o,
  output logic arm_commit_o,
  output logic arm_o, run_permit_o, stop_o, isolate_o, irq_o,
  output logic [3:0] state_o
);
  localparam logic [3:0] UNQUALIFIED = 0, STARTUP = 1, CONFIGURATION = 2,
    READY = 3, RUNNING = 4, CLOSING = 5, STOPPED = 6, FAULT = 7;
  localparam logic [31:0] OK = 0, ACCEPTED = 1, INVALID_REQUEST = 2,
    STALE_COMMAND = 3, COMMAND_BUSY = 4, UNSUPPORTED_PROFILE = 5,
    INVALID_STATE = 6, NOT_QUALIFIED = 7, NO_CAPACITY = 8, STOP_ACTIVE = 9,
    CANCELLED = 10, CONFIGURATION_FAILED = 11, CLOSED_CLEAN = 12,
    CLOSED_LOSS = 13, CLOSED_UNCERTAIN = 14, ALREADY_STOPPED = 15,
    FAULT_LATCHED = 16, EMPTY = 17;
  localparam logic [31:0] SUPERVISOR = 32'h00010000, CONFIG_TIMEOUT = 32'h00020000,
    SERVICE_ERROR = 32'h00040000, STALE_BACKEND = 32'h00080000,
    CANCEL_TIMEOUT = 32'h00100000, CLOSE_TIMEOUT = 32'h00200000,
    EVENT_OVERFLOW = 32'h00400000, COUNTER_FULL = 32'h00800000,
    INTERNAL = 32'h01000000, QUALIFICATION_LOSS = 32'h02000000,
    CPU_RESET = 32'h04000000, CPU_HALT = 32'h08000000,
    SOFTWARE_STOP = 32'h10000000, FAULT_MASK = 32'h03ffffff;
  logic [3:0] state_q, state_d;
  logic [767:0] shadow_q, shadow_d, candidate_q, candidate_d, active_q, active_d;
  logic candidate_valid_q, candidate_valid_d, active_valid_q, active_valid_d;
  logic session_valid_q, session_valid_d;
  logic [127:0] session_q, session_d;
  logic [63:0] command_q, command_d, object_q, object_d, last_command_q, last_command_d;
  logic [63:0] high_config_q, high_config_d, operation_q, operation_d;
  logic [63:0] admission_id_q, admission_id_d, completion_id_q, completion_id_d;
  logic [31:0] admission_code_q, admission_code_d, completion_code_q, completion_code_d;
  logic operation_busy_q, operation_busy_d, completion_valid_q, completion_valid_d;
  logic cancelling_q, cancelling_d, fault_latched_q, fault_latched_d;
  logic isolate_q, isolate_d, exhausted_q, exhausted_d, epoch_open_q, epoch_open_d;
  logic [63:0] tick_q, epoch_q, epoch_d, first_tick_q, first_tick_d;
  logic timebase_exhausted;
  logic [31:0] service_age_q, service_age_d, cancel_age_q, cancel_age_d, close_age_q, close_age_d;
  logic terminal_pending_q, terminal_pending_d, terminal_valid_q, terminal_valid_d;
  logic [63:0] terminal_epoch_q, terminal_epoch_d;
  logic [31:0] terminal_code_q, terminal_code_d;
  logic stop_busy_q, stop_busy_d, stop_valid_q, stop_valid_d;
  logic [63:0] stop_epoch_q, stop_epoch_d, stop_id_q, stop_id_d;
  logic epoch_loss_q, epoch_loss_d, epoch_uncertain_q, epoch_uncertain_d, time_uncertain_q, time_uncertain_d;
  logic [31:0] stop_code_q, stop_code_d;
  logic [31:0] sticky_q, sticky_d, fault_history_q;
  logic [3:0] irq_mask_q, irq_mask_d, pending_q, pending_d;
  logic [63:0] event_sequence_q, event_sequence_d, fault_count_q, fault_count_d;
  logic [63:0] lost_count_q, lost_count_d, snapshot_id_q, snapshot_id_d;
  logic event_valid_q, event_valid_d, snapshot_valid_q, snapshot_valid_d;
  logic [511:0] first_fault_q, first_fault_d, latest_fault_q, latest_fault_d, event_q, event_d;
  logic [31:0] snapshot_q [0:127];
  logic cpu_reset_q, cpu_halt_q, supervisor_q, emergency_q, arm_q, arm_d;
  logic accept, shape_ok, mmio_error, snapshot_take;
  logic [31:0] mmio_data, reasons, event_flags, result, close_code;
  logic [511:0] occurrence;
  logic [767:0] selected_config;
  logic config_shape, config_binding, candidate_binding, active_binding, session_binding;
  logic stop_level, stop_request, fatal_level, fail_service, cancel_complete, config_complete;
  logic command_new, service_response_match, close_match, close_finished;
  logic fault_occurrence, count_exhaustion, sequence_known, software_stop;
  integer word_index;

  /* the shared timestamp has no CPU enable, halt or reset path. */
  drg5_acquisition_timebase timebase (
    .clk_i, .system_reset_i, .tick_o(tick_q), .exhausted_o(timebase_exhausted)
  );

  /* profile one names the entire fixed ADC tuple; all alternate selectors are rejected. */
  function automatic logic supported(input logic [223:0] cfg);
    supported = cfg[31:0] == 1 && cfg[63:32] == 1600 &&
      cfg[95:64] == 80000000 && cfg[127:96] == 32'h33 &&
      cfg[159:128] == 32'hff && cfg[191:160] == 0 && cfg[223:192] == 0;
  endfunction

  /* descriptor identity and manifest binding are mandatory even for synthetic qualification. */
  function automatic logic descriptor_shape(input logic [543:0] cfg);
    descriptor_shape = cfg[63:0] != 0 && cfg[319:64] != 0 &&
      cfg[447:320] != 0 && cfg[511:448] != 0 &&
      cfg[543:512] >= 1 && cfg[543:512] <= 1048576;
  endfunction

  /* bus ownership ends with a retained response, never with completion of slow service. */
  assign req_ready_o = !system_reset_i && (!rsp_valid_o || rsp_ready_i);
  assign accept = req_valid_i && req_ready_o;
  assign shape_ok = req_addr_i[1:0] == 0 && req_wstrb_i == (req_write_i ? 4'hf : 4'h0);
  assign state_o = state_q;
  assign epoch_o = epoch_q;
  assign first_tick_o = first_tick_q;
  assign tick_o = tick_q;
  /* a sibling scheduler commits this future binding on the command acceptance edge. */
  assign arm_commit_o = arm_d && !system_reset_i;
  assign arm_commit_epoch_o = epoch_d;
  assign arm_commit_first_tick_o = first_tick_d;
  assign session_binding = session_verified_i && session_id_i != 0 &&
    (!session_valid_q || session_id_i == session_q);
  assign selected_config = req_wdata_i == 3 ? candidate_q : shadow_q;
  assign config_shape = descriptor_shape({selected_config[735:256], selected_config[63:0]});
  assign config_binding = qualification_valid_i && session_binding &&
    selected_config[639:512] == session_id_i &&
    selected_config[63:0] == qualification_config_id_i &&
    selected_config[511:256] == qualification_digest_i &&
    selected_config[703:640] == qualification_timebase_id_i &&
    selected_config[735:704] == qualification_manifest_length_i;
  assign candidate_binding = qualification_valid_i && session_binding &&
    candidate_q[639:512] == session_id_i &&
    candidate_q[63:0] == qualification_config_id_i &&
    candidate_q[511:256] == qualification_digest_i &&
    candidate_q[703:640] == qualification_timebase_id_i &&
    candidate_q[735:704] == qualification_manifest_length_i;
  assign active_binding = active_valid_q && session_binding && active_q[639:512] == session_id_i;
  assign stop_level = emergency_stop_i || cpu_reset_i || cpu_halt_i;
  assign software_stop = accept && shape_ok && req_write_i && req_addr_i == 12'h028 && req_wdata_i == 1;
  assign stop_request = stop_level || software_stop;
  assign fatal_level = supervisor_fault_i || fault_i != 0 || exhausted_q ||
    ((state_q == READY || state_q == RUNNING) && (!physical_ready_i || !active_binding)) ||
    ((state_q == STARTUP || state_q == CONFIGURATION) && !candidate_binding);
  /* these vetoes remain effective with a stalled CPU response or full event queue. */
  assign stop_o = stop_request || fatal_level || (reasons & FAULT_MASK) != 0 ||
    state_q == CLOSING || state_q == FAULT;
  assign isolate_o = isolate_q || supervisor_fault_i || exhausted_q;
  assign run_permit_o = state_q == RUNNING && !stop_o;
  /* ARM delivers an accepted epoch binding even if a later STOP vetoes its first trigger. */
  assign arm_o = arm_q;
  assign service_valid_o = operation_busy_q && (state_q == STARTUP || state_q == CONFIGURATION);
  assign service_cancel_o = service_valid_o && cancelling_q;
  assign service_phase_o = cancelling_q ? 2'd2 : state_q == STARTUP ? 2'd0 : 2'd1;
  assign service_command_id_o = operation_q;
  assign service_config_o = candidate_q;
  assign close_request_o = state_q == CLOSING && epoch_open_q;
  /* a retained terminal qualifies only the current closed epoch, never an earlier run. */
  assign terminal_sealed_o = terminal_valid_q && terminal_epoch_q == epoch_q && !epoch_open_q;
  assign irq_o = |(pending_q & irq_mask_q);

  /* one combinational transition owns all command, service and evidence arbitration. */
  always_comb begin
    state_d = state_q; shadow_d = shadow_q; candidate_d = candidate_q; active_d = active_q;
    candidate_valid_d = candidate_valid_q; active_valid_d = active_valid_q;
    session_valid_d = session_valid_q; session_d = session_q;
    command_d = command_q; object_d = object_q; last_command_d = last_command_q;
    high_config_d = high_config_q; operation_d = operation_q;
    admission_id_d = admission_id_q; admission_code_d = admission_code_q;
    completion_id_d = completion_id_q; completion_code_d = completion_code_q;
    operation_busy_d = operation_busy_q; completion_valid_d = completion_valid_q;
    cancelling_d = cancelling_q; fault_latched_d = fault_latched_q;
    isolate_d = isolate_q; exhausted_d = exhausted_q; epoch_open_d = epoch_open_q;
    epoch_d = epoch_q; first_tick_d = first_tick_q;
    service_age_d = service_age_q; cancel_age_d = cancel_age_q; close_age_d = close_age_q;
    terminal_pending_d = terminal_pending_q; terminal_valid_d = terminal_valid_q;
    terminal_epoch_d = terminal_epoch_q; terminal_code_d = terminal_code_q;
    stop_busy_d = stop_busy_q; stop_valid_d = stop_valid_q;
    stop_epoch_d = stop_epoch_q; stop_code_d = stop_code_q; stop_id_d = stop_id_q;
    epoch_loss_d = epoch_loss_q; epoch_uncertain_d = epoch_uncertain_q; time_uncertain_d = time_uncertain_q;
    sticky_d = sticky_q; irq_mask_d = irq_mask_q; pending_d = pending_q;
    event_sequence_d = event_sequence_q; fault_count_d = fault_count_q; lost_count_d = lost_count_q;
    snapshot_id_d = snapshot_id_q; snapshot_valid_d = snapshot_valid_q;
    first_fault_d = first_fault_q; latest_fault_d = latest_fault_q; event_d = event_q;
    event_valid_d = event_valid_q; arm_d = 0;
    mmio_data = 0; mmio_error = 0; snapshot_take = 0; reasons = 0;
    event_flags = 0; occurrence = 0; result = OK; close_code = CLOSED_UNCERTAIN;
    command_new = 0; fail_service = 0; cancel_complete = 0; config_complete = 0;
    close_finished = 0; fault_occurrence = 0; count_exhaustion = 0; sequence_known = 1;
    word_index = 0;
    service_response_match = service_valid_o && backend_command_id_i == operation_q &&
      backend_phase_i == service_phase_o;
    close_match = state_q == CLOSING && epoch_open_q && close_epoch_i == epoch_q;

    /* the timestamp saturates; CPU reset never resets this timebase. */
    if (timebase_exhausted) begin
      if (!exhausted_q) reasons |= COUNTER_FULL;
      exhausted_d = 1;
    end
    /* external fault levels create one occurrence per newly asserted cause. */
    reasons |= (fault_i & ~fault_history_q) & 32'h0000ffff;
    if (|(fault_i & ~fault_history_q & 32'hffff0000)) reasons |= INTERNAL;
    if (supervisor_fault_i && !supervisor_q) reasons |= SUPERVISOR;
    if (cpu_reset_i && !cpu_reset_q) reasons |= CPU_RESET;
    if (cpu_halt_i && !cpu_halt_q) reasons |= CPU_HALT;
    /* loss of a bound descriptor or physical readiness revokes active qualification. */
    if (((state_q == READY || state_q == RUNNING) && (!active_binding || !physical_ready_i)) ||
        ((state_q == STARTUP || state_q == CONFIGURATION) && !candidate_binding)) begin
      reasons |= QUALIFICATION_LOSS;
    end
    /* responses are single-cycle beats; no old identity can complete newer work. */
    if (backend_valid_i && !service_response_match) reasons |= STALE_BACKEND;
    if (close_valid_i && !close_match) reasons |= STALE_BACKEND;
    if (state_q > FAULT) reasons |= INTERNAL;

    /* MMIO reads return either scalar state or an explicitly frozen snapshot. */
    if (accept) begin
      /* malformed beats perform no register or command side effect. */
      if (!shape_ok) begin
        mmio_error = 1; mmio_data = INVALID_REQUEST;
      /* writes to staging and service registers complete on this edge. */
      end else if (req_write_i) begin
        /* shadow words can change without mutating an accepted candidate or active descriptor. */
        if (req_addr_i >= 12'h100 && req_addr_i <= 12'h15c) begin
          word_index = (int'(req_addr_i) - 32'h100) >> 2;
          shadow_d[word_index * 32 +: 32] = req_wdata_i;
        /* only named scalar writes have defined side effects. */
        end else begin
          case (req_addr_i)
            12'h010: command_d[31:0] = req_wdata_i;
            12'h014: command_d[63:32] = req_wdata_i;
            12'h018: object_d[31:0] = req_wdata_i;
            12'h01c: object_d[63:32] = req_wdata_i;
            /* ordinary requests reserve a separate, retained completion slot. */
            12'h020: begin
              command_new = command_q != 0 && command_q > last_command_q;
              /* precedence makes malformed, stale and busy results independent of configuration. */
              if (req_wdata_i < 1 || req_wdata_i > 3 || command_q == 0 ||
                  ((req_wdata_i == 1 || (req_wdata_i == 3 && candidate_valid_q)) && selected_config[767:736] != 0)) result = INVALID_REQUEST;
              else if (!command_new) result = STALE_COMMAND;
              else if (operation_busy_q || completion_valid_q) result = COMMAND_BUSY;
              else if ((req_wdata_i == 1 || (req_wdata_i == 3 && candidate_valid_q)) &&
                       !supported({selected_config[767:736], selected_config[255:64]})) result = UNSUPPORTED_PROFILE;
              else if ((req_wdata_i == 1 && !(state_q == UNQUALIFIED || state_q == READY || state_q == STOPPED)) ||
                       (req_wdata_i == 2 && state_q != READY) ||
                       (req_wdata_i == 3 && !(state_q == FAULT || state_q == STOPPED))) result = INVALID_STATE;
              else if (stop_request || stop_busy_q || stop_valid_q) result = STOP_ACTIVE;
              else if (fatal_level || (reasons & FAULT_MASK) != 0 || exhausted_q || time_uncertain_q ||
                       terminal_pending_q || epoch_open_q || !ownership_clear_i || !pins_idle_i) result = NOT_QUALIFIED;
              else if (req_wdata_i != 2 && (!config_shape || !config_binding ||
                       (req_wdata_i == 3 && !candidate_valid_q))) result = NOT_QUALIFIED;
              else if (req_wdata_i == 1 && selected_config[63:0] <= high_config_q) result = STALE_COMMAND;
              else if (req_wdata_i == 2 && (!active_valid_q || !active_binding || !physical_ready_i ||
                       !metadata_archived_i || object_q != active_q[63:0] || event_valid_q ||
                       fault_latched_q || epoch_q == COUNTER_LIMIT || &tick_q || !arm_ready_i)) result = NOT_QUALIFIED;
              else if (req_wdata_i == 2 && free_blocks_i < 24) result = NO_CAPACITY;
              else result = ACCEPTED;
              admission_id_d = command_q; admission_code_d = result; mmio_data = result;
              /* busy leaves the new sequence retryable; other well-formed new requests consume it. */
              if (command_new && req_wdata_i >= 1 && req_wdata_i <= 3 &&
                  result != COMMAND_BUSY && result != INVALID_REQUEST) last_command_d = command_q;
              /* accepted service captures a complete descriptor before exposing any backend request. */
              if (result == ACCEPTED) begin
                operation_d = command_q; completion_id_d = command_q;
                /* ARM publishes its binding immediately; capture remains a separate integration task. */
                if (req_wdata_i == 2) begin
                  state_d = RUNNING; epoch_d = epoch_q + 1'b1; first_tick_d = tick_q + 1'b1;
                  epoch_open_d = 1; epoch_loss_d = 0; epoch_uncertain_d = 0;
                  arm_d = 1; completion_valid_d = 1; completion_code_d = OK;
                /* startup and configuration share one deadline and one reserved completion. */
                end else begin
                  candidate_d = selected_config; candidate_valid_d = 1; active_valid_d = 0;
                  session_d = session_id_i; session_valid_d = 1; operation_busy_d = 1;
                  service_age_d = 0; cancel_age_d = 0; cancelling_d = 0; state_d = STARTUP;
                  isolate_d = 0;
                  if (req_wdata_i == 1) high_config_d = selected_config[63:0];
                end
              end
            end
            /* completion acknowledgment never releases storage or evidence. */
            12'h024: begin
              if (req_wdata_i != 1) mmio_data = INVALID_REQUEST;
              else if (!completion_valid_q || object_q != completion_id_q) mmio_data = STALE_COMMAND;
              else completion_valid_d = 0;
            end
            /* repeated STOP joins the retained request or result without allocating a second closure. */
            12'h028: begin
              if (req_wdata_i != 1) mmio_data = INVALID_REQUEST;
              else if (stop_valid_q) mmio_data = stop_code_q;
              else if (stop_busy_q) mmio_data = ACCEPTED;
              else if (&stop_id_q) mmio_data = NOT_QUALIFIED;
              /* a fresh STOP owns one independent result slot. */
              else begin
                stop_id_d = stop_id_q + 1'b1;
                stop_epoch_d = epoch_open_q ? epoch_q : 64'b0;
                /* active service and capture finish through autonomous bounded paths. */
                if (state_q == RUNNING || state_q == CLOSING || service_valid_o) begin
                  stop_busy_d = 1; mmio_data = ACCEPTED;
                /* idle requests have an immediate retained result. */
                end else begin
                  stop_valid_d = 1; stop_code_d = state_q == FAULT ? FAULT_LATCHED : ALREADY_STOPPED;
                  mmio_data = stop_code_d;
                end
              end
            end
            /* matching STOP acknowledgment does not alter an epoch terminal. */
            12'h02c: begin
              if (req_wdata_i != 1) mmio_data = INVALID_REQUEST;
              else if (!stop_valid_q || object_q != stop_id_q) mmio_data = STALE_COMMAND;
              else stop_valid_d = 0;
            end
            /* snapshot reservation freezes all multibit observations until identified release. */
            12'h030: begin
              if (req_wdata_i != 1) mmio_data = INVALID_REQUEST;
              else if (snapshot_valid_q) mmio_data = COMMAND_BUSY;
              /* identity exhaustion must remain observable without another coherent snapshot. */
              else if (snapshot_id_q == COUNTER_LIMIT) begin
                mmio_data = NOT_QUALIFIED; exhausted_d = 1;
                if (!exhausted_q) reasons |= COUNTER_FULL;
              end
              /* a free slot receives a fresh identity and coherent pre-edge image. */
              else begin
                snapshot_take = 1; snapshot_valid_d = 1;
                snapshot_id_d = snapshot_id_q + 1'b1; mmio_data = ACCEPTED;
              end
            end
            /* event acknowledgment frees only the matching notification entry. */
            12'h034: begin
              if (req_wdata_i != 1) mmio_data = INVALID_REQUEST;
              else if (!event_valid_q || object_q != event_q[63:0]) mmio_data = STALE_COMMAND;
              else event_valid_d = 0;
            end
            /* archival acknowledgment releases delivery, never the retained terminal summary. */
            12'h038: begin
              if (req_wdata_i != 1) mmio_data = INVALID_REQUEST;
              else if (!terminal_pending_q || object_q != terminal_epoch_q) mmio_data = STALE_COMMAND;
              else terminal_pending_d = 0;
            end
            /* IRQ clearing affects notification only; live sources reassert below. */
            12'h03c: begin
              if (req_wdata_i[31:4] != 0) mmio_data = INVALID_REQUEST;
              else pending_d = pending_q & ~req_wdata_i[3:0];
            end
            /* masking the CPU line cannot mask hardware stop or evidence collection. */
            12'h040: begin
              if (req_wdata_i[31:4] != 0) mmio_data = INVALID_REQUEST;
              else irq_mask_d = req_wdata_i[3:0];
            end
            /* stale snapshot release cannot replace a newer frozen observation. */
            12'h048: begin
              if (req_wdata_i != 1) mmio_data = INVALID_REQUEST;
              else if (!snapshot_valid_q || object_q != snapshot_id_q) mmio_data = STALE_COMMAND;
              else snapshot_valid_d = 0;
            end
            /* unassigned addresses have no side effect or implicit alias. */
            default: begin
              mmio_error = 1; mmio_data = INVALID_REQUEST;
            end
          endcase
        end
      /* arrays are read-only except for the explicitly writable shadow bank. */
      end else begin
        /* shadow reads return the currently staged word only. */
        if (req_addr_i >= 12'h100 && req_addr_i <= 12'h15c) begin
          word_index = (int'(req_addr_i) - 32'h100) >> 2;
          mmio_data = shadow_q[word_index * 32 +: 32];
        /* coherent active reads use the frozen copy when a snapshot is held. */
        end else if (req_addr_i >= 12'h200 && req_addr_i <= 12'h25c) begin
          word_index = (int'(req_addr_i) - 32'h200) >> 2;
          if (snapshot_valid_q) mmio_data = snapshot_q[96 + word_index];
          else mmio_data = EMPTY;
        /* an unreserved snapshot bank exposes no stale bytes as current status. */
        end else if (req_addr_i >= 12'h300 && req_addr_i <= 12'h4fc) begin
          word_index = (int'(req_addr_i) - 32'h300) >> 2;
          if (snapshot_valid_q) mmio_data = snapshot_q[word_index];
          else mmio_data = EMPTY;
        /* single-word status reads do not acknowledge any source. */
        end else begin
          case (req_addr_i)
            12'h000: mmio_data = 32'h41435143;
            12'h004: mmio_data = 32'h00010000;
            12'h008: mmio_data = {28'b0, state_q};
            12'h010: mmio_data = command_q[31:0];
            12'h014: mmio_data = command_q[63:32];
            12'h018: mmio_data = object_q[31:0];
            12'h01c: mmio_data = object_q[63:32];
            12'h028: mmio_data = stop_valid_q ? stop_code_q : stop_busy_q ? ACCEPTED : EMPTY;
            12'h040: mmio_data = {28'b0, irq_mask_q};
            12'h044: mmio_data = {28'b0, pending_q};
            12'h04c: mmio_data = first_fault_q[287:256];
            12'h050: mmio_data = latest_fault_q[287:256];
            12'h054: mmio_data = sticky_q;
            /* unassigned addresses have no side effect or implicit alias. */
            default: begin
              mmio_error = 1; mmio_data = INVALID_REQUEST;
            end
          endcase
        end
      end
    end

    /* service completion is subordinate to physical faults and STOP on the same edge. */
    if (service_valid_o) begin
      service_age_d = service_age_q + 1'b1;
      /* cancellation requires a matching termination response and proof of idle ownership. */
      if (cancelling_q) begin
        cancel_age_d = cancel_age_q + 1'b1;
        cancel_complete = backend_valid_i && service_response_match && backend_ok_i && pins_idle_i && ownership_clear_i;
        /* a failed or late termination cannot certify the old service as retired. */
        if ((!cancel_complete && cancel_age_q >= 32'(CANCEL_CYCLES - 1)) ||
            (backend_valid_i && service_response_match && !cancel_complete)) begin
          reasons |= CANCEL_TIMEOUT; fail_service = 1; isolate_d = 1;
        end
      /* STOP begins bounded cancellation and suppresses a simultaneous success. */
      end else if (stop_request) begin
        cancelling_d = 1; cancel_age_d = 0; active_valid_d = 0;
      /* matching startup success advances to configuration without resetting the total deadline. */
      end else if (backend_valid_i && service_response_match) begin
        /* backend failure or incomplete final qualification is a terminal service fault. */
        if (!backend_ok_i || (state_q == CONFIGURATION &&
            (!pins_idle_i || !ownership_clear_i || !physical_ready_i || !candidate_binding))) begin
          reasons |= SERVICE_ERROR; fail_service = 1;
        /* startup ownership remains live until the configuration response. */
        end else if (state_q == STARTUP) begin
          state_d = CONFIGURATION;
        /* final configuration publishes the captured candidate, never current shadow bytes. */
        end else begin
          config_complete = 1;
        end
      end
      /* exact-deadline completion wins; partial progress cannot extend the overall timeout. */
      if (!config_complete && !cancel_complete && service_age_q >= 32'(CONFIG_CYCLES - 1)) begin
        reasons |= CONFIG_TIMEOUT; fail_service = 1; isolate_d = 1;
      end
    end

    /* software STOP is a cause only when it terminates owned service or recording. */
    if ((software_stop || (emergency_stop_i && !emergency_q)) && !stop_busy_q && !stop_valid_q &&
        (state_q == RUNNING || (service_valid_o && !cancelling_q))) reasons |= SOFTWARE_STOP;
    /* asynchronous external STOP owns its own result just like the MMIO service path. */
    if (emergency_stop_i && !emergency_q && !stop_busy_q && !stop_valid_q && !(&stop_id_q)) begin
      stop_id_d = stop_id_q + 1'b1;
      stop_epoch_d = epoch_open_q ? epoch_q : 64'b0;
      /* owned work requires a later bounded result. */
      if (state_q == RUNNING || state_q == CLOSING || service_valid_o) stop_busy_d = 1;
      /* idle emergency requests return an immediate, retained result. */
      else begin
        stop_valid_d = 1; stop_code_d = state_q == FAULT ? FAULT_LATCHED : ALREADY_STOPPED;
      end
    end

    /* closure waits for a tagged containment result and has its own finite deadline. */
    if (state_q == CLOSING) begin
      close_age_d = close_age_q + 1'b1;
      /* clean and counted-loss closures both require proven old ownership containment. */
      if (close_valid_i && close_match && close_result_i <= 2 && ownership_clear_i && pins_idle_i) begin
        close_finished = 1;
        close_code = close_result_i == 0 ? CLOSED_CLEAN : close_result_i == 1 ? CLOSED_LOSS : CLOSED_UNCERTAIN;
      /* a malformed response is observable and never certifies containment. */
      end else if (close_valid_i && close_match) begin
        reasons |= SERVICE_ERROR;
      end
      /* exact-deadline closure wins over timeout. */
      if (!close_finished && close_age_q >= 32'(CLOSE_CYCLES - 1)) begin
        reasons |= CLOSE_TIMEOUT; close_finished = 1; close_code = CLOSED_UNCERTAIN; isolate_d = 1;
      end
    end

    /* timing uncertainty persists until a new isolated system lifetime. */
    if (supervisor_fault_i || exhausted_d) time_uncertain_d = 1;

    /* lost events remain counted outside the queue; a same-edge acknowledgment makes room. */
    if (reasons != 0) begin
      /* the sequence numbers occurrences, including events dropped behind the retained head. */
      if (event_sequence_q < COUNTER_LIMIT) event_sequence_d = event_sequence_q + 1'b1;
      else sequence_known = 0;
      /* reaching the final sequence prevents any future ambiguous continuation. */
      if (event_sequence_d == COUNTER_LIMIT) begin
        reasons |= COUNTER_FULL; count_exhaustion = 1;
      end
      /* count every known undeliverable occurrence, including exhausted identities. */
      if (event_valid_d || !sequence_known) begin
        if (event_valid_d) reasons |= EVENT_OVERFLOW;
        if (lost_count_q < COUNTER_LIMIT) lost_count_d = lost_count_q + 1'b1;
        /* saturation preserves a lower bound and forces uncertain containment. */
        if (lost_count_d == COUNTER_LIMIT) begin
          reasons |= COUNTER_FULL; count_exhaustion = 1;
        end
      end
      fault_occurrence = (reasons & FAULT_MASK) != 0;
      /* fault counts exclude clean software stop and CPU halt/reset observations. */
      if (fault_occurrence) begin
        if (fault_count_q < COUNTER_LIMIT) fault_count_d = fault_count_q + 1'b1;
        /* exhausted fault accounting cannot certify future exact outcomes. */
        if (fault_count_d == COUNTER_LIMIT) begin
          reasons |= COUNTER_FULL; count_exhaustion = 1;
        end
      end
      if (count_exhaustion) exhausted_d = 1;
      event_flags = {28'b0, sequence_known, !(time_uncertain_d || exhausted_d), epoch_open_q, session_valid_q};
      /* offending response identities are preserved instead of relabeled as current work. */
      if (backend_valid_i && !service_response_match) begin
        event_flags[4] = 1; event_flags[7:6] = backend_phase_i;
      end
      if (close_valid_i && !close_match) event_flags[5] = 1;
      occurrence = {(close_valid_i && !close_match) ? close_epoch_i :
        operation_busy_q ? candidate_q[63:0] : active_q[63:0], session_q, event_flags, reasons,
        (backend_valid_i && !service_response_match) ? backend_command_id_i : operation_busy_q ? operation_q : 64'b0,
        epoch_open_q ? epoch_q : 64'b0,
        tick_q, event_sequence_d};
      /* first/latest evidence is independent of event delivery and IRQ acknowledgment. */
      if (fault_occurrence) begin
        if (first_fault_q[287:256] == 0) first_fault_d = occurrence;
        latest_fault_d = occurrence; fault_latched_d = 1; pending_d[0] = 1;
      end
      /* only a free entry receives the new event; old evidence is never overwritten. */
      if (!event_valid_d && sequence_known) begin
        event_d = occurrence; event_valid_d = 1;
      end
      sticky_d |= reasons;
      /* per-epoch causes never inherit unrelated faults from an earlier stopped interval. */
      if (epoch_open_q && (reasons & ~SOFTWARE_STOP) != 0) epoch_loss_d = 1;
      if (epoch_open_q && (reasons & (SUPERVISOR | COUNTER_FULL | CLOSE_TIMEOUT | INTERNAL)) != 0) epoch_uncertain_d = 1;
    end

    /* critical decisions depend on causes directly, not on notification capacity. */
    if (fatal_level || (reasons & FAULT_MASK) != 0 || exhausted_d) begin
      active_valid_d = 0; fault_latched_d = 1;
      /* service faults complete the owned command even if its MMIO response remains stalled. */
      if (operation_busy_q) fail_service = 1;
      /* an open epoch still needs a bounded terminal outcome. */
      if (epoch_open_q && state_q != CLOSING) begin
        state_d = CLOSING; close_age_d = 0;
      /* an idle controller faults without inventing an epoch or closure. */
      end else if (state_q != CLOSING) begin
        state_d = FAULT;
      end
      if (supervisor_fault_i || exhausted_d || (reasons & (CANCEL_TIMEOUT | CONFIG_TIMEOUT | INTERNAL)) != 0) isolate_d = 1;
    /* CPU and software stops close capture without needing firmware to drain it. */
    end else if (state_q == RUNNING && stop_request) begin
      state_d = CLOSING; close_age_d = 0;
    end

    /* fault wins over cancellation, which wins over successful configuration. */
    if (fail_service) begin
      operation_busy_d = 0; completion_valid_d = 1; completion_code_d = CONFIGURATION_FAILED;
      active_valid_d = 0; cancelling_d = 0; state_d = FAULT; isolate_d = 1;
      /* STOP receives a failure result without claiming safe service cancellation. */
      if (stop_busy_d) begin
        stop_busy_d = 0; stop_valid_d = 1; stop_code_d = FAULT_LATCHED;
      end
    /* a positive termination response permits cancellation to return to unqualified idle. */
    end else if (cancel_complete) begin
      operation_busy_d = 0; completion_valid_d = 1; completion_code_d = CANCELLED;
      cancelling_d = 0; active_valid_d = 0; state_d = UNQUALIFIED;
      /* autonomous CPU cancellation need not fabricate a STOP reply without a requester. */
      if (stop_busy_d) begin
        stop_busy_d = 0; stop_valid_d = 1; stop_code_d = ALREADY_STOPPED;
      end
    /* only full backend success installs immutable active bytes. */
    end else if (config_complete && !stop_request) begin
      operation_busy_d = 0; completion_valid_d = 1; completion_code_d = OK;
      active_d = candidate_q; active_valid_d = 1; state_d = READY;
      fault_latched_d = 0; isolate_d = 0;
    end

    /* terminal reporting preserves faults and uncertainty even if the backend claimed clean. */
    if (close_finished) begin
      if (exhausted_d || epoch_uncertain_d || time_uncertain_d) close_code = CLOSED_UNCERTAIN;
      else if (close_code == CLOSED_CLEAN && epoch_loss_d) close_code = CLOSED_LOSS;
      terminal_valid_d = 1; terminal_pending_d = 1; terminal_epoch_d = epoch_q; terminal_code_d = close_code;
      epoch_open_d = 0; active_valid_d = 0;
      state_d = close_code == CLOSED_UNCERTAIN || fault_latched_d ? FAULT : STOPPED;
      /* the final STOP result belongs only to an admitted independent STOP request. */
      if (stop_busy_d) begin
        stop_busy_d = 0; stop_valid_d = 1; stop_code_d = close_code;
      end
    end
    /* source levels reassert after W1C; fault acknowledgment cannot clear qualification. */
    pending_d[1] = event_valid_d;
    pending_d[2] = terminal_pending_d;
    pending_d[3] = completion_valid_d || stop_valid_d;
  end

  /* isolated whole-system reset is the only authority that erases retained control ownership. */
  always_ff @(posedge clk_i) begin
    /* integration must fence both bus and backend owners before this destructive reset. */
    if (system_reset_i) begin
      state_q <= UNQUALIFIED; shadow_q <= 0; candidate_q <= 0; active_q <= 0;
      candidate_valid_q <= 0; active_valid_q <= 0; session_valid_q <= 0; session_q <= 0;
      command_q <= 0; object_q <= 0; last_command_q <= 0; high_config_q <= 0; operation_q <= 0;
      admission_id_q <= 0; admission_code_q <= EMPTY; completion_id_q <= 0; completion_code_q <= EMPTY;
      operation_busy_q <= 0; completion_valid_q <= 0; cancelling_q <= 0; fault_latched_q <= 0;
      isolate_q <= 0; exhausted_q <= 0; epoch_open_q <= 0;
      epoch_q <= 0; first_tick_q <= 0;
      service_age_q <= 0; cancel_age_q <= 0; close_age_q <= 0;
      terminal_pending_q <= 0; terminal_valid_q <= 0; terminal_epoch_q <= 0; terminal_code_q <= EMPTY;
      stop_busy_q <= 0; stop_valid_q <= 0; stop_epoch_q <= 0; stop_id_q <= 0; stop_code_q <= EMPTY;
      epoch_loss_q <= 0; epoch_uncertain_q <= 0; time_uncertain_q <= 0;
      sticky_q <= 0; irq_mask_q <= 0; pending_q <= 0;
      event_sequence_q <= 0; fault_count_q <= 0; lost_count_q <= 0;
      snapshot_id_q <= 0; snapshot_valid_q <= 0;
      first_fault_q <= 0; latest_fault_q <= 0; event_q <= 0; event_valid_q <= 0;
      fault_history_q <= 0; cpu_reset_q <= 0; cpu_halt_q <= 0; supervisor_q <= 0; emergency_q <= 0; arm_q <= 0;
      rsp_valid_o <= 0; rsp_rdata_o <= 0; rsp_tag_o <= 0; rsp_error_o <= 0;
      /* no pre-reset observation is exposed as a current snapshot. */
      for (integer i = 0; i < 128; i = i + 1) snapshot_q[i] <= 0;
    /* CPU halt/reset cannot enter this destructive reset branch. */
    end else begin
      state_q <= state_d; shadow_q <= shadow_d; candidate_q <= candidate_d; active_q <= active_d;
      candidate_valid_q <= candidate_valid_d; active_valid_q <= active_valid_d;
      session_valid_q <= session_valid_d; session_q <= session_d;
      command_q <= command_d; object_q <= object_d; last_command_q <= last_command_d;
      high_config_q <= high_config_d; operation_q <= operation_d;
      admission_id_q <= admission_id_d; admission_code_q <= admission_code_d;
      completion_id_q <= completion_id_d; completion_code_q <= completion_code_d;
      operation_busy_q <= operation_busy_d; completion_valid_q <= completion_valid_d;
      cancelling_q <= cancelling_d; fault_latched_q <= fault_latched_d;
      isolate_q <= isolate_d; exhausted_q <= exhausted_d; epoch_open_q <= epoch_open_d;
      epoch_q <= epoch_d; first_tick_q <= first_tick_d;
      service_age_q <= service_age_d; cancel_age_q <= cancel_age_d; close_age_q <= close_age_d;
      terminal_pending_q <= terminal_pending_d; terminal_valid_q <= terminal_valid_d;
      terminal_epoch_q <= terminal_epoch_d; terminal_code_q <= terminal_code_d;
      stop_busy_q <= stop_busy_d; stop_valid_q <= stop_valid_d;
      stop_epoch_q <= stop_epoch_d; stop_code_q <= stop_code_d; stop_id_q <= stop_id_d;
      epoch_loss_q <= epoch_loss_d; epoch_uncertain_q <= epoch_uncertain_d; time_uncertain_q <= time_uncertain_d;
      sticky_q <= sticky_d; irq_mask_q <= irq_mask_d; pending_q <= pending_d;
      event_sequence_q <= event_sequence_d; fault_count_q <= fault_count_d; lost_count_q <= lost_count_d;
      snapshot_id_q <= snapshot_id_d; snapshot_valid_q <= snapshot_valid_d;
      first_fault_q <= first_fault_d; latest_fault_q <= latest_fault_d; event_q <= event_d; event_valid_q <= event_valid_d;
      fault_history_q <= fault_i; cpu_reset_q <= cpu_reset_i; cpu_halt_q <= cpu_halt_i;
      supervisor_q <= supervisor_fault_i; emergency_q <= emergency_stop_i; arm_q <= arm_d;
      /* a stalled bus response stays stable while autonomous service continues. */
      if (rsp_valid_o && rsp_ready_i) rsp_valid_o <= 0;
      /* replacement on the acknowledgment edge sustains one accepted beat per clock. */
      if (accept) begin
        rsp_valid_o <= 1; rsp_rdata_o <= mmio_data; rsp_tag_o <= req_tag_i; rsp_error_o <= mmio_error;
      end
      /* all snapshot fields describe the same pre-edge state; only its identity is newly allocated. */
      if (snapshot_take) begin
        /* reserved words are deterministic zeros rather than stale implementation storage. */
        for (integer i = 0; i < 128; i = i + 1) snapshot_q[i] <= 0;
        snapshot_q[0] <= {28'b0, state_q};
        snapshot_q[1] <= {16'b0, pins_idle_i, ownership_clear_i, isolate_o,
          epoch_uncertain_q, epoch_loss_q, time_uncertain_q, cancelling_q, exhausted_q, fault_latched_q,
          stop_valid_q, stop_busy_q, terminal_pending_q, event_valid_q, completion_valid_q,
          operation_busy_q, active_valid_q};
        snapshot_q[2] <= tick_q[31:0]; snapshot_q[3] <= tick_q[63:32];
        snapshot_q[4] <= epoch_q[31:0]; snapshot_q[5] <= epoch_q[63:32];
        snapshot_q[6] <= first_tick_q[31:0]; snapshot_q[7] <= first_tick_q[63:32];
        snapshot_q[8] <= last_command_q[31:0]; snapshot_q[9] <= last_command_q[63:32];
        snapshot_q[10] <= operation_q[31:0]; snapshot_q[11] <= operation_q[63:32];
        snapshot_q[12] <= completion_id_q[31:0]; snapshot_q[13] <= completion_id_q[63:32];
        snapshot_q[14] <= completion_code_q; snapshot_q[15] <= {28'b0, pending_q};
        snapshot_q[16] <= event_sequence_q[31:0]; snapshot_q[17] <= event_sequence_q[63:32];
        snapshot_q[18] <= fault_count_q[31:0]; snapshot_q[19] <= fault_count_q[63:32];
        snapshot_q[20] <= lost_count_q[31:0]; snapshot_q[21] <= lost_count_q[63:32];
        snapshot_q[22] <= sticky_q; snapshot_q[23] <= {28'b0, irq_mask_q};
        snapshot_q[24] <= snapshot_id_d[31:0]; snapshot_q[25] <= snapshot_id_d[63:32];
        snapshot_q[26] <= admission_id_q[31:0]; snapshot_q[27] <= admission_id_q[63:32];
        snapshot_q[28] <= admission_code_q;
        snapshot_q[30] <= high_config_q[31:0]; snapshot_q[31] <= high_config_q[63:32];
        /* evidence objects share the same sixteen-word encoding. */
        for (integer i = 0; i < 16; i = i + 1) begin
          snapshot_q[32 + i] <= first_fault_q[i * 32 +: 32];
          snapshot_q[48 + i] <= latest_fault_q[i * 32 +: 32];
          snapshot_q[64 + i] <= event_q[i * 32 +: 32];
        end
        snapshot_q[80] <= terminal_epoch_q[31:0]; snapshot_q[81] <= terminal_epoch_q[63:32];
        snapshot_q[82] <= terminal_code_q; snapshot_q[83] <= {31'b0, terminal_valid_q};
        snapshot_q[84] <= stop_id_q[31:0]; snapshot_q[85] <= stop_id_q[63:32];
        snapshot_q[86] <= stop_code_q; snapshot_q[87] <= {31'b0, stop_valid_q};
        snapshot_q[88] <= session_q[31:0]; snapshot_q[89] <= session_q[63:32];
        snapshot_q[90] <= session_q[95:64]; snapshot_q[91] <= session_q[127:96];
        snapshot_q[92] <= active_q[671:640]; snapshot_q[93] <= active_q[703:672];
        snapshot_q[94] <= stop_epoch_q[31:0]; snapshot_q[95] <= stop_epoch_q[63:32];
        /* the active bank is frozen with the state that qualifies its bytes. */
        for (integer i = 0; i < 24; i = i + 1) snapshot_q[96 + i] <= active_q[i * 32 +: 32];
      end
    end
  end

`ifndef SYNTHESIS
  /* invalid test parameters cannot silently weaken the finite-deadline model. */
  initial begin
    if (CONFIG_CYCLES < 1 || CANCEL_CYCLES < 1 || CLOSE_CYCLES < 1 || COUNTER_LIMIT == 0)
      $fatal(1, "invalid acquisition control parameters");
  end
`endif
endmodule
