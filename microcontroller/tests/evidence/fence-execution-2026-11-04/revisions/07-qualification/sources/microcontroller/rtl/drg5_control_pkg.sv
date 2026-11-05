/* define instruction identity, execution metadata and retained fault context. */
package drg5_control_pkg;
  /* OP_MACHINE decodes raw instructions with the configured M, C, Zifencei and IRQ features. */
  typedef enum logic [3:0] {
    OP_RESULT, OP_LOAD, OP_STORE, OP_CSR, OP_MRET, OP_ECALL,
    OP_EBREAK, OP_REDIRECT, OP_CONTROL, OP_MEMORY, OP_BASE, OP_FENCE, OP_MACHINE, OP_WFI, OP_FENCE_I
  } op_t;

  /* select CSR updates independently of read/write suppression. */
  typedef enum logic [1:0] {
    CSR_READ, CSR_WRITE, CSR_SET, CSR_CLEAR
  } csr_op_t;

  /* preserve supplied instruction identity, operands and fault context. */
  typedef struct packed {
    logic [31:0] pc, raw;
    logic [3:0] raw_valid;
    logic [2:0] length;
    logic expanded_valid;
    logic [31:0] expanded;
    op_t op;
    logic rs1_used, rs2_used;
    logic [4:0] rs1, rs2, rd;
    logic [31:0] rs1_value, rs2_value;
    logic rd_write;
    logic [31:0] result, next_pc;
    logic [31:0] mem_addr, mem_wdata; // store data is lane-positioned
    logic [1:0] mem_size;
    logic mem_signed;
    logic [11:0] csr_addr;
    csr_op_t csr_op;
    logic csr_read, csr_write;
    logic [31:0] csr_source;
    logic fault;
    logic [31:0] cause, mtval;
  } packet_t;

  /* keep request ownership separate from the stage owning this token. */
  typedef struct packed {
    packet_t p;
    logic [63:0] uid;
    logic admitted; // asynchronous entry must drain this instruction attempt
    logic mem_issued, mem_done; // issued work survives an ordinary flush
    logic mem_decoded;
    logic c_decoded; // short identity validated by the internal decompressor
    logic alu_decoded, alu_a_pc, alu_b_imm;
    logic md_decoded, md_issued, md_done; // one arithmetic job per UID
    logic [2:0] md_op;
    logic [3:0] alu_op;
    logic base_serial, serial_ready;
    logic [3:0] cf_kind;
    logic [2:0] cf_cond;
    logic [31:0] cf_imm; // decoded instruction immediate
    logic cf_taken;
  } token_t;

  /* preserve the first containment event across hart reset until isolated recovery. */
  typedef struct packed {
    logic valid, owned, accepted, responded;
    logic [2:0] reason; // 1 protocol, 2 uncertain, 3 deadline, 4 tag, 5 UID
    logic [63:0] uid;
    logic [31:0] pc, addr, wdata, tag;
    logic [1:0] size;
    logic [3:0] wstrb;
    logic write;
  } fatal_record_t;

  /* observe one terminal attempt; trap records are not retirements. */
  typedef struct packed {
    logic valid, trap;
    logic [63:0] uid, order;
    packet_t packet;
    logic rd_write;
    logic [4:0] rd;
    logic [31:0] value, next_pc;
    logic csr_read, csr_write;
    logic [31:0] csr_old, csr_new;
  } trace_t;
endpackage
