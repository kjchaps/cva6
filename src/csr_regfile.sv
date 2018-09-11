// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich
// Date: 05.05.2017
// Description: CSR Register File as specified by RISC-V

import ariane_pkg::*;

module csr_regfile #(
    parameter int          ASID_WIDTH      = 1,
    parameter int unsigned NR_COMMIT_PORTS = 2
)(
    input  logic                  clk_i,                      // Clock
    input  logic                  rst_ni,                     // Asynchronous reset active low
    input  logic                  time_irq_i,                 // Timer threw a interrupt

    // send a flush request out if a CSR with a side effect has changed (e.g. written)
    output logic                  flush_o,
    output logic                  halt_csr_o,                 // halt requested
    // commit acknowledge
    input  scoreboard_entry_t [NR_COMMIT_PORTS-1:0] commit_instr_i, // the instruction we want to commit
    input  logic [NR_COMMIT_PORTS-1:0]              commit_ack_i,   // Commit acknowledged a instruction -> increase instret CSR
    // Core and Cluster ID
    input  logic  [3:0]           core_id_i,                  // Core ID is considered static
    input  logic  [5:0]           cluster_id_i,               // Cluster ID is considered static
    input  logic  [63:0]          boot_addr_i,                // Address from which to start booting, mtvec is set to the same address
    // we are taking an exception
    input exception_t             ex_i,                       // We've got an exception from the commit stage, take its

    input  fu_op                  csr_op_i,                   // Operation to perform on the CSR file
    input  logic  [11:0]          csr_addr_i,                 // Address of the register to read/write
    input  logic  [63:0]          csr_wdata_i,                // Write data in
    output logic  [63:0]          csr_rdata_o,                // Read data out
    input  logic                  csr_write_fflags_i,         // Write fflags register e.g.: we are retiring a floating point instruction
    input  logic  [63:0]          pc_i,                       // PC of instruction accessing the CSR
    output exception_t            csr_exception_o,            // attempts to access a CSR without appropriate privilege
                                                              // level or to write  a read-only register also
                                                              // raises illegal instruction exceptions.
    // Interrupts/Exceptions
    output logic  [63:0]          epc_o,                      // Output the exception PC to PC Gen, the correct CSR (mepc, sepc) is set accordingly
    output logic                  eret_o,                     // Return from exception, set the PC of epc_o
    output logic  [63:0]          trap_vector_base_o,         // Output base of exception vector, correct CSR is output (mtvec, stvec)
    output riscv::priv_lvl_t      priv_lvl_o,                 // Current privilege level the CPU is in
    // FPU
    output logic [4:0]            fflags_o,                   // Floating-Point Accured Exceptions
    output logic [2:0]            frm_o,                      // Floating-Point Dynamic Rounding Mode
    // MMU
    output logic                  en_translation_o,           // enable VA translation
    output logic                  en_ld_st_translation_o,     // enable VA translation for load and stores
    output riscv::priv_lvl_t      ld_st_priv_lvl_o,           // Privilege level at which load and stores should happen
    output logic                  sum_o,
    output logic                  mxr_o,
    output logic [43:0]           satp_ppn_o,
    output logic [ASID_WIDTH-1:0] asid_o,
    // external interrupts
    input  logic [1:0]            irq_i,                      // external interrupt in
    input  logic                  ipi_i,                      // inter processor interrupt -> connected to machine mode sw
    input  logic                  debug_req_i,                // debug request in
    output logic                  set_debug_pc_o,
    // Virtualization Support
    output logic                  tvm_o,                      // trap virtual memory
    output logic                  tw_o,                       // timeout wait
    output logic                  tsr_o,                      // trap sret
    output logic                  debug_mode_o,               // we are in debug mode -> that will change some decoding
    output logic                  single_step_o,              // we are in single-step mode
    // Caches
    output logic                  icache_en_o,                // L1 ICache Enable
    output logic                  dcache_en_o,                // L1 DCache Enable
    // Performance Counter
    output logic  [11:0]          perf_addr_o,                // address to performance counter module
    output logic  [63:0]          perf_data_o,                // write data to performance counter module
    input  logic  [63:0]          perf_data_i,                // read data from performance counter module
    output logic                  perf_we_o
);
    // internal signal to keep track of access exceptions
    logic        read_access_exception, update_access_exception;
    logic        csr_we, csr_read;
    logic [63:0] csr_wdata, csr_rdata;
    riscv::priv_lvl_t   trap_to_priv_lvl;
    // register for enabling load store address translation, this is critical, hence the register
    logic        en_ld_st_translation_d, en_ld_st_translation_q;
    logic  mprv;
    logic  mret;  // return from M-mode exception
    logic  sret;  // return from S-mode exception
    logic  dret;  // return from debug mode

    riscv::csr_t  csr_addr;
    // ----------------
    // Assignments
    // ----------------
    assign csr_addr = riscv::csr_t'(csr_addr_i);
    // ----------------
    // CSR Registers
    // ----------------
    // privilege level register
    riscv::priv_lvl_t   priv_lvl_d, priv_lvl_q;
    // we are in debug
    logic        debug_mode_q, debug_mode_d;
    logic [63:0] next_pc;

    riscv::status_rv64_t  mstatus_q,  mstatus_d;
    riscv::satp_t         satp_q, satp_d;
    riscv::dcsr_t         dcsr_q,     dcsr_d;

    logic        mtvec_rst_load_q;// used to determine whether we came out of reset

    logic [63:0] dpc_q,       dpc_d;
    logic [63:0] dscratch0_q, dscratch0_d;
    logic [63:0] mtvec_q,     mtvec_d;
    logic [63:0] medeleg_q,   medeleg_d;
    logic [63:0] mideleg_q,   mideleg_d;
    logic [63:0] mip_q,       mip_d;
    logic [63:0] pmpcfg0_q,   pmpcfg0_d;
    logic [63:0] pmpaddr0_q,  pmpaddr0_d;
    logic [63:0] mie_q,       mie_d;
    logic [63:0] mscratch_q,  mscratch_d;
    logic [63:0] mepc_q,      mepc_d;
    logic [63:0] mcause_q,    mcause_d;
    logic [63:0] mtval_q,     mtval_d;

    logic [63:0] stvec_q,     stvec_d;
    logic [63:0] sscratch_q,  sscratch_d;
    logic [63:0] sepc_q,      sepc_d;
    logic [63:0] scause_q,    scause_d;
    logic [63:0] stval_q,     stval_d;
    logic [63:0] dcache_q,    dcache_d;
    logic [63:0] icache_q,    icache_d;

    logic        wfi_d,       wfi_q;

    logic [63:0] cycle_q,     cycle_d;
    logic [63:0] instret_q,   instret_d;

    riscv::fcsr_t fcsr_q, fcsr_d;

    // ----------------
    // CSR Read logic
    // ----------------
    always_comb begin : csr_read_process
        // a read access exception can only occur if we attempt to read a CSR which does not exist
        read_access_exception = 1'b0;
        csr_rdata = 64'b0;
        // feed through address of performance counter
        perf_addr_o = csr_addr.address;

        if (csr_read) begin
            case (csr_addr.address)
                riscv::CSR_FFLAGS:             csr_rdata = {59'b0, fcsr_q.fflags};
                riscv::CSR_FRM:                csr_rdata = {61'b0, fcsr_q.frm};
                riscv::CSR_FCSR:               csr_rdata = {32'b0, fcsr_q};
                // debug registers
                riscv::CSR_DCSR:               csr_rdata = {32'b0, dcsr_q};
                riscv::CSR_DPC:                csr_rdata = dpc_q;
                riscv::CSR_DSCRATCH0:          csr_rdata = dscratch0_q;
                // trigger module registers
                riscv::CSR_TSELECT:; // not implemented
                riscv::CSR_TDATA1:;  // not implemented
                riscv::CSR_TDATA2:;  // not implemented
                riscv::CSR_TDATA3:;  // not implemented
                // supervisor registers
                riscv::CSR_SSTATUS:            csr_rdata = mstatus_q & riscv::SMODE_STATUS_MASK;
                riscv::CSR_SIE:                csr_rdata = mie_q & mideleg_q;
                riscv::CSR_SIP:                csr_rdata = mip_q & mideleg_q;
                riscv::CSR_STVEC:              csr_rdata = stvec_q;
                riscv::CSR_SCOUNTEREN:         csr_rdata = 64'b0; // not implemented
                riscv::CSR_SSCRATCH:           csr_rdata = sscratch_q;
                riscv::CSR_SEPC:               csr_rdata = sepc_q;
                riscv::CSR_SCAUSE:             csr_rdata = scause_q;
                riscv::CSR_STVAL:              csr_rdata = stval_q;
                riscv::CSR_SATP: begin
                    // intercept reads to SATP if in S-Mode and TVM is enabled
                    if (priv_lvl_o == riscv::PRIV_LVL_S && mstatus_q.tvm)
                        read_access_exception = 1'b1;
                    else
                        csr_rdata = satp_q;
                end
                // machine mode registers
                riscv::CSR_MSTATUS:            csr_rdata = mstatus_q;
                riscv::CSR_MISA:               csr_rdata = ISA_CODE;
                riscv::CSR_MEDELEG:            csr_rdata = medeleg_q;
                riscv::CSR_MIDELEG:            csr_rdata = mideleg_q;
                riscv::CSR_MIE:                csr_rdata = mie_q;
                riscv::CSR_MTVEC:              csr_rdata = mtvec_q;
                riscv::CSR_MCOUNTEREN:         csr_rdata = 64'b0; // not implemented
                riscv::CSR_MSCRATCH:           csr_rdata = mscratch_q;
                riscv::CSR_MEPC:               csr_rdata = mepc_q;
                riscv::CSR_MCAUSE:             csr_rdata = mcause_q;
                riscv::CSR_MTVAL:              csr_rdata = mtval_q;
                riscv::CSR_MIP:                csr_rdata = mip_q;
                // Placeholders for M-mode protection
                riscv::CSR_PMPCFG0:            csr_rdata = pmpcfg0_q;
                riscv::CSR_PMPADDR0:           csr_rdata = pmpaddr0_q;
                riscv::CSR_MVENDORID:          csr_rdata = 64'b0; // not implemented
                riscv::CSR_MARCHID:            csr_rdata = 64'b0; // PULP, anonymous source (no allocated ID yet)
                riscv::CSR_MIMPID:             csr_rdata = 64'b0; // not implemented
                riscv::CSR_MHARTID:            csr_rdata = {53'b0, cluster_id_i[5:0], 1'b0, core_id_i[3:0]};
                riscv::CSR_MCYCLE:             csr_rdata = cycle_q;
                riscv::CSR_MINSTRET:           csr_rdata = instret_q;
                // custom (non RISC-V) cache control
                riscv::CSR_DCACHE:             csr_rdata = dcache_q;
                riscv::CSR_ICACHE:             csr_rdata = icache_q;
                // Counters and Timers
                riscv::CSR_CYCLE:              csr_rdata = cycle_q;
                riscv::CSR_INSTRET:            csr_rdata = instret_q;
                riscv::CSR_L1_ICACHE_MISS,
                riscv::CSR_L1_DCACHE_MISS,
                riscv::CSR_ITLB_MISS,
                riscv::CSR_DTLB_MISS,
                riscv::CSR_LOAD,
                riscv::CSR_STORE,
                riscv::CSR_EXCEPTION,
                riscv::CSR_EXCEPTION_RET,
                riscv::CSR_BRANCH_JUMP,
                riscv::CSR_CALL,
                riscv::CSR_RET,
                riscv::CSR_MIS_PREDICT:        csr_rdata = perf_data_i;
                default: read_access_exception = 1'b1;
            endcase
        end
    end
    // ---------------------------
    // CSR Write and update logic
    // ---------------------------
    always_comb begin : csr_update
        automatic riscv::satp_t sapt;
        automatic logic [63:0] mip;
        automatic logic [63:0] instret;

        sapt = satp_q;
        mip = csr_wdata & 64'h33;
        instret = instret_q;
        // only FCSR, USIP, SSIP, UTIP, STIP are write-able

        eret_o                  = 1'b0;
        flush_o                 = 1'b0;
        update_access_exception = 1'b0;

        set_debug_pc_o          = 1'b0;

        perf_we_o               = 1'b0;
        perf_data_o             = 'b0;

        fcsr_d                  = fcsr_q;

        priv_lvl_d              = priv_lvl_q;
        debug_mode_d            = debug_mode_q;
        dcsr_d                  = dcsr_q;
        dpc_d                   = dpc_q;
        dscratch0_d             = dscratch0_q;
        mstatus_d               = mstatus_q;

        // check whether we come out of reset
        // this is a workaround. some tools have issues
        // having boot_addr_i in the asynchronous
        // reset assignment to mtvec_d, even though
        // boot_addr_i will be assigned a constant
        // on the top-level.
        if (mtvec_rst_load_q) begin
            mtvec_d             = boot_addr_i + 'h40;
        end else begin
            mtvec_d             = mtvec_q;
        end

        medeleg_d               = medeleg_q;
        mideleg_d               = mideleg_q;
        mip_d                   = mip_q;
        mie_d                   = mie_q;
        mepc_d                  = mepc_q;
        mcause_d                = mcause_q;
        mscratch_d              = mscratch_q;
        mtval_d                 = mtval_q;
        dcache_d                = dcache_q;
        icache_d                = icache_q;

        sepc_d                  = sepc_q;
        scause_d                = scause_q;
        stvec_d                 = stvec_q;
        sscratch_d              = sscratch_q;
        stval_d                 = stval_q;
        satp_d                  = satp_q;
        en_ld_st_translation_d  = en_ld_st_translation_q;

        // check for correct access rights and that we are writing
        if (csr_we) begin
            case (csr_addr.address)
                // Floating-Point
                riscv::CSR_FFLAGS: begin
                    fcsr_d.fflags = csr_wdata[4:0];
                    // this instruction has side-effects
                    flush_o = 1'b1;
                end
                riscv::CSR_FRM: begin
                    fcsr_d.frm    = csr_wdata[2:0];
                    // this instruction has side-effects
                    flush_o = 1'b1;
                end
                riscv::CSR_FCSR: begin
                    fcsr_d[7:0]   = csr_wdata[7:0]; // ignore writes to reserved space
                    // this instruction has side-effects
                    flush_o = 1'b1;
                end
                // debug CSR
                riscv::CSR_DCSR: begin
                    dcsr_d = csr_wdata[31:0];
                    // debug is implemented
                    dcsr_d.xdebugver = 4'h4;
                    // currently not supported
                    dcsr_d.nmip      = 1'b0;
                    dcsr_d.stopcount = 1'b0;
                    dcsr_d.stoptime  = 1'b0;
                end
                riscv::CSR_DPC:                dpc_d = csr_wdata;
                riscv::CSR_DSCRATCH0:          dscratch0_d = csr_wdata;
                // trigger module CSRs
                riscv::CSR_TSELECT:; // not implemented
                riscv::CSR_TDATA1:;  // not implemented
                riscv::CSR_TDATA2:;  // not implemented
                riscv::CSR_TDATA3:;  // not implemented
                // sstatus is a subset of mstatus - mask it accordingly
                riscv::CSR_SSTATUS: begin
                    mstatus_d = csr_wdata;
                    // also hardwire the registers for sstatus
                    mstatus_d.sxl  = riscv::XLEN_64;
                    mstatus_d.uxl  = riscv::XLEN_64;
                    // hardwired zero registers
                    mstatus_d.sd   = 1'b0;
                    mstatus_d.xs   = 2'b0;
                    mstatus_d.fs   = 2'b0;
                    mstatus_d.upie = 1'b0;
                    mstatus_d.uie  = 1'b0;
                    // not all fields of mstatus can be written
                    mstatus_d.mie  = mstatus_q.mie;
                    mstatus_d.mpie = mstatus_q.mpie;
                    mstatus_d.mpp  = mstatus_q.mpp;
                    mstatus_d.mprv = mstatus_q.mprv;
                    mstatus_d.tsr  = mstatus_q.tsr;
                    mstatus_d.tw   = mstatus_q.tw;
                    mstatus_d.tvm  = mstatus_q.tvm;
                    // this instruction has side-effects
                    flush_o = 1'b1;
                end
                // even machine mode interrupts can be visible and set-able to supervisor
                // if the corresponding bit in mideleg is set
                riscv::CSR_SIE: begin
                    // the mideleg makes sure only delegate-able register (and therefore also only implemented registers)
                    // are written
                    for (int unsigned i = 0; i < 64; i++)
                        if (mideleg_q[i])
                            mie_d[i] = csr_wdata[i];
                end

                riscv::CSR_SIP: begin
                    for (int unsigned i = 0; i < 64; i++)
                        if (mideleg_q[i])
                            mip_d[i] = mip[i];
                end

                riscv::CSR_SCOUNTEREN:;
                riscv::CSR_STVEC:              stvec_d     = {csr_wdata[63:2], 1'b0, csr_wdata[0]};
                riscv::CSR_SSCRATCH:           sscratch_d  = csr_wdata;
                riscv::CSR_SEPC:               sepc_d      = {csr_wdata[63:1], 1'b0};
                riscv::CSR_SCAUSE:             scause_d    = csr_wdata;
                riscv::CSR_STVAL:              stval_d     = csr_wdata;
                // supervisor address translation and protection
                riscv::CSR_SATP: begin
                    // intercept SATP writes if in S-Mode and TVM is enabled
                    if (priv_lvl_o == riscv::PRIV_LVL_S && mstatus_q.tvm)
                        update_access_exception = 1'b1;
                    else begin
                        sapt      = riscv::satp_t'(csr_wdata);
                        // only make ASID_LEN - 1 bit stick, that way software can figure out how many ASID bits are supported
                        sapt.asid = sapt.asid & {{(16-ASID_WIDTH){1'b0}}, {ASID_WIDTH{1'b1}}};
                        satp_d    = sapt;
                    end
                    // changing the mode can have side-effects on address translation (e.g.: other instructions), re-fetch
                    // the next instruction by executing a flush
                    flush_o = 1'b1;
                end

                riscv::CSR_MSTATUS: begin
                    mstatus_d      = csr_wdata;
                    mstatus_d.sxl  = riscv::XLEN_64;
                    mstatus_d.uxl  = riscv::XLEN_64;
                    // hardwired zero registers
                    mstatus_d.sd   = 1'b0;
                    mstatus_d.xs   = 2'b0;
                    mstatus_d.fs   = 2'b0;
                    mstatus_d.upie = 1'b0;
                    mstatus_d.uie  = 1'b0;
                    // this register has side-effects on other registers, flush the pipeline
                    flush_o        = 1'b1;
                end
                // MISA is WARL (Write Any Value, Reads Legal Value)
                riscv::CSR_MISA:;
                // machine exception delegation register
                // 0 - 15 exceptions supported
                riscv::CSR_MEDELEG:            medeleg_d   = csr_wdata & 64'hF7FF;
                // machine interrupt delegation register
                // we do not support user interrupt delegation
                riscv::CSR_MIDELEG:            mideleg_d   = csr_wdata & 64'hBBB;

                // mask the register so that unsupported interrupts can never be set
                riscv::CSR_MIE:                mie_d       = csr_wdata & 64'hBBB; // we only support supervisor and m-mode interrupts

                riscv::CSR_MTVEC: begin
                    mtvec_d     = {csr_wdata[63:2], 1'b0, csr_wdata[0]};
                    // we are in vector mode, this implementation requires the additional
                    // alignment constraint of 64 * 4 bytes
                    if (csr_wdata[0])
                        mtvec_d = {csr_wdata[63:8], 7'b0, csr_wdata[0]};
                end
                riscv::CSR_MCOUNTEREN:;

                riscv::CSR_MSCRATCH:           mscratch_d  = csr_wdata;
                riscv::CSR_MEPC:               mepc_d      = {csr_wdata[63:1], 1'b0};
                riscv::CSR_MCAUSE:             mcause_d    = csr_wdata;
                riscv::CSR_MTVAL:              mtval_d     = csr_wdata;
                riscv::CSR_MIP:                mip_d       = mip;
                // Placeholders for M-mode protection
                riscv::CSR_PMPCFG0:            pmpcfg0_d   = csr_wdata;
                riscv::CSR_PMPADDR0:           pmpaddr0_d  = csr_wdata;
                // performance counters
                riscv::CSR_MCYCLE:             cycle_d     = csr_wdata;
                riscv::CSR_MINSTRET:           instret     = csr_wdata;
                riscv::CSR_DCACHE:             dcache_d    = csr_wdata[0]; // enable bit
                riscv::CSR_ICACHE:             icache_d    = csr_wdata[0]; // enable bit
                riscv::CSR_L1_ICACHE_MISS,
                riscv::CSR_L1_DCACHE_MISS,
                riscv::CSR_ITLB_MISS,
                riscv::CSR_DTLB_MISS,
                riscv::CSR_LOAD,
                riscv::CSR_STORE,
                riscv::CSR_EXCEPTION,
                riscv::CSR_EXCEPTION_RET,
                riscv::CSR_BRANCH_JUMP,
                riscv::CSR_CALL,
                riscv::CSR_RET,
                riscv::CSR_MIS_PREDICT: begin
                                        perf_data_o = csr_wdata;
                                        perf_we_o   = 1'b1;
                end
                default: update_access_exception = 1'b1;
            endcase
        end

        // write the floating point status register
        if (csr_write_fflags_i)
            fcsr_d.fflags = csr_wdata_i[4:0] | fcsr_q.fflags;

        // ---------------------
        // External Interrupts
        // ---------------------
        // Machine Mode External Interrupt Pending
        mip_d[11] = mie_q[11] & irq_i[1];
        mip_d[9] = mie_q[9] & irq_i[0];
        // Machine software interrupt
        mip_d[3] = mie_q[3] & ipi_i;
        // Timer interrupt pending, coming from platform timer
        mip_d[7] = time_irq_i;

        // -----------------------
        // Manage Exception Stack
        // -----------------------
        // update exception CSRs
        // we got an exception update cause, pc and stval register
        trap_to_priv_lvl = riscv::PRIV_LVL_M;
        // Exception is taken and we are not in debug mode
        // exceptions in debug mode don't update any fields
        if (!debug_mode_q && ex_i.valid) begin
            // do not flush, flush is reserved for CSR writes with side effects
            flush_o   = 1'b0;
            // figure out where to trap to
            // a m-mode trap might be delegated if we are taking it in S mode
            // first figure out if this was an exception or an interrupt e.g.: look at bit 63
            // the cause register can only be 6 bits long (as we only support 64 exceptions)
            if ((ex_i.cause[63] && mideleg_q[ex_i.cause[5:0]]) ||
                (~ex_i.cause[63] && medeleg_q[ex_i.cause[5:0]])) begin
                // traps never transition from a more-privileged mode to a less privileged mode
                // so if we are already in M mode, stay there
                trap_to_priv_lvl = (priv_lvl_o == riscv::PRIV_LVL_M) ? riscv::PRIV_LVL_M : riscv::PRIV_LVL_S;
            end

            // trap to supervisor mode
            if (trap_to_priv_lvl == riscv::PRIV_LVL_S) begin
                // update sstatus
                mstatus_d.sie  = 1'b0;
                mstatus_d.spie = mstatus_q.sie;
                // this can either be user or supervisor mode
                mstatus_d.spp  = logic'(priv_lvl_q);
                // set cause
                scause_d       = ex_i.cause;
                // set epc
                sepc_d         = pc_i;
                // set mtval or stval
                stval_d        = ex_i.tval;
            // trap to machine mode
            end else begin
                // update mstatus
                mstatus_d.mie  = 1'b0;
                mstatus_d.mpie = mstatus_q.mie;
                // save the previous privilege mode
                mstatus_d.mpp  = priv_lvl_q;
                mcause_d       = ex_i.cause;
                // set epc
                mepc_d         = pc_i;
                // set mtval or stval
                mtval_d        = ex_i.tval;
            end

            priv_lvl_d = trap_to_priv_lvl;

        end

        // ------------------------------
        // Debug
        // ------------------------------
        // Explains why Debug Mode was entered.
        // When there are multiple reasons to enter Debug Mode in a single cycle, hardware should set cause to the cause with the highest priority.
        // 1: An ebreak instruction was executed. (priority 3)
        // 2: The Trigger Module caused a breakpoint exception. (priority 4)
        // 3: The debugger requested entry to Debug Mode. (priority 2)
        // 4: The hart single stepped because step was set. (priority 1)
        // we are currently not in debug mode and could potentially enter
        if (!debug_mode_q) begin
            dcsr_d.prv = priv_lvl_o;
            // trigger module fired

            // caused by a breakpoint
            if (ex_i.valid && ex_i.cause == riscv::BREAKPOINT) begin
                // check that we actually want to enter debug depending on the privilege level we are currently in
                unique case (priv_lvl_o)
                    riscv::PRIV_LVL_M: begin
                        debug_mode_d = dcsr_q.ebreakm;
                        set_debug_pc_o = dcsr_q.ebreakm;
                    end
                    riscv::PRIV_LVL_S: begin
                        debug_mode_d = dcsr_q.ebreaks;
                        set_debug_pc_o = dcsr_q.ebreaks;
                    end
                    riscv::PRIV_LVL_U: begin
                        debug_mode_d = dcsr_q.ebreaku;
                        set_debug_pc_o = dcsr_q.ebreaku;
                    end
                    default:;
                endcase
                // save PC of next this instruction e.g.: the next one to be executed
                dpc_d = pc_i;
                dcsr_d.cause = dm::CauseBreakpoint;
            end

            // we've got a debug request (and we have an instruction which we can associate it to)
            if (debug_req_i && commit_instr_i[0].valid) begin
                // save the PC
                dpc_d = pc_i;
                // enter debug mode
                debug_mode_d = 1'b1;
                // jump to the base address
                set_debug_pc_o = 1'b1;
                // save the cause as external debug request
                dcsr_d.cause = dm::CauseRequest;
            end

            // single step enable and we just retired an instruction
            if (dcsr_q.step && (|commit_ack_i)) begin
                dpc_d = next_pc;
                debug_mode_d = 1'b1;
                set_debug_pc_o = 1'b1;
                dcsr_d.cause = dm::CauseSingleStep;
            end
        end
        // go in halt-state again when we encounter an exception
        if (debug_mode_q && ex_i.valid && ex_i.cause == riscv::BREAKPOINT) begin
            set_debug_pc_o = 1'b1;
        end

        // ------------------------------
        // MPRV - Modify Privilege Level
        // ------------------------------
        // Set the address translation at which the load and stores should occur
        // we can use the previous values since changing the address translation will always involve a pipeline flush
        if (mprv && satp_q.mode == MODE_SV39 && (mstatus_q.mpp != riscv::PRIV_LVL_M))
            en_ld_st_translation_d = 1'b1;
        else // otherwise we go with the regular settings
            en_ld_st_translation_d = en_translation_o;

        ld_st_priv_lvl_o = (mprv) ? mstatus_q.mpp : priv_lvl_o;
        en_ld_st_translation_o = en_ld_st_translation_q;
        // ------------------------------
        // Return from Environment
        // ------------------------------
        // When executing an xRET instruction, supposing xPP holds the value y, xIE is set to xPIE; the privilege
        // mode is changed to y; xPIE is set to 1; and xPP is set to U
        if (mret) begin
            // return from exception, IF doesn't care from where we are returning
            eret_o = 1'b1;
            // return to the previous privilege level and restore all enable flags
            // get the previous machine interrupt enable flag
            mstatus_d.mie  = mstatus_q.mpie;
            // restore the previous privilege level
            priv_lvl_d     = mstatus_q.mpp;
            // set mpp to user mode
            mstatus_d.mpp  = riscv::PRIV_LVL_U;
            // set mpie to 1
            mstatus_d.mpie = 1'b1;
        end

        if (sret) begin
            // return from exception, IF doesn't care from where we are returning
            eret_o = 1'b1;
            // return the previous supervisor interrupt enable flag
            mstatus_d.sie  = mstatus_d.spie;
            // restore the previous privilege level
            priv_lvl_d     = riscv::priv_lvl_t'({1'b0, mstatus_d.spp});
            // set spp to user mode
            mstatus_d.spp  = logic'(riscv::PRIV_LVL_U);
            // set spie to 1
            mstatus_d.spie = 1'b1;
        end

        // return from debug mode
        if (dret) begin
            // return from exception, IF doesn't care from where we are returning
            eret_o = 1'b1;
            // restore the previous privilege level
            priv_lvl_d     = riscv::priv_lvl_t'(dcsr_q.prv);
            // actually return from debug mode
            debug_mode_d = 1'b0;
        end

        // --------------------
        // Counters
        // --------------------
        // just increment the cycle count
        cycle_d = cycle_q + 1'b1;
        // increase instruction retired counter
        for (int i = 0; i < NR_COMMIT_PORTS; i++) begin
            if (commit_ack_i[i]) begin
                instret++;
            end
        end
        instret_d = instret;
    end

    // ---------------------------
    // CSR OP Select Logic
    // ---------------------------
    always_comb begin : csr_op_logic
        csr_wdata = csr_wdata_i;
        csr_we    = 1'b1;
        csr_read  = 1'b1;
        mret      = 1'b0;
        sret      = 1'b0;
        dret      = 1'b0;

        unique case (csr_op_i)
            CSR_WRITE: csr_wdata = csr_wdata_i;
            CSR_SET:   csr_wdata = csr_wdata_i | csr_rdata;
            CSR_CLEAR: csr_wdata = (~csr_wdata_i) & csr_rdata;
            CSR_READ:  csr_we    = 1'b0;
            SRET: begin
                // the return should not have any write or read side-effects
                csr_we   = 1'b0;
                csr_read = 1'b0;
                sret     = 1'b1; // signal a return from supervisor mode
            end
            MRET: begin
                // the return should not have any write or read side-effects
                csr_we   = 1'b0;
                csr_read = 1'b0;
                mret     = 1'b1; // signal a return from machine mode
            end
            DRET: begin
                // the return should not have any write or read side-effects
                csr_we   = 1'b0;
                csr_read = 1'b0;
                dret     = 1'b1; // signal a return from debug mode
            end // DRET:
            default: begin
                csr_we   = 1'b0;
                csr_read = 1'b0;
            end
        endcase
        // if we are retiring an exception do not return from exception
        if (ex_i.valid) begin
            mret = 1'b0;
            sret = 1'b0;
            dret = 1'b0;
        end
    end

    logic interrupt_global_enable;
    // --------------------------------------
    // Exception Control & Interrupt Control
    // --------------------------------------
    always_comb begin : exception_ctrl
        automatic logic [63:0] interrupt_cause;
        interrupt_cause = '0;
        // wait for interrupt register
        wfi_d = wfi_q;

        csr_exception_o = {
            64'b0, 64'b0, 1'b0
        };
        // -----------------
        // Interrupt Control
        // -----------------
        // we decode an interrupt the same as an exception, hence it will be taken if the instruction did not
        // throw any previous exception.
        // we have three interrupt sources: external interrupts, software interrupts, timer interrupts (order of precedence)
        // for two privilege levels: Supervisor and Machine Mode
        // Supervisor Timer Interrupt
        if (mie_q[riscv::S_TIMER_INTERRUPT[5:0]] && mip_q[riscv::S_TIMER_INTERRUPT[5:0]])
            interrupt_cause = riscv::S_TIMER_INTERRUPT;
        // Supervisor Software Interrupt
        if (mie_q[riscv::S_SW_INTERRUPT[5:0]] && mip_q[riscv::S_SW_INTERRUPT[5:0]])
            interrupt_cause = riscv::S_SW_INTERRUPT;
        // Supervisor External Interrupt
        if (mie_q[riscv::S_EXT_INTERRUPT[5:0]] && mip_q[riscv::S_EXT_INTERRUPT[5:0]])
            interrupt_cause = riscv::S_EXT_INTERRUPT;
        // Machine Timer Interrupt
        if (mip_q[riscv::M_TIMER_INTERRUPT[5:0]] && mie_q[riscv::M_TIMER_INTERRUPT[5:0]])
            interrupt_cause = riscv::M_TIMER_INTERRUPT;
        // Machine Mode Software Interrupt
        if (mip_q[riscv::M_SW_INTERRUPT[5:0]] && mie_q[riscv::M_SW_INTERRUPT[5:0]])
            interrupt_cause = riscv::M_SW_INTERRUPT;
        // Machine Mode External Interrupt
        if (mip_q[riscv::M_EXT_INTERRUPT[5:0]] && mie_q[riscv::M_EXT_INTERRUPT[5:0]])
            interrupt_cause = riscv::M_EXT_INTERRUPT;

        // An interrupt i will be taken if bit i is set in both mip and mie, and if interrupts are globally enabled.
        // By default, M-mode interrupts are globally enabled if the hart’s current privilege mode  is less
        // than M, or if the current privilege mode is M and the MIE bit in the mstatus register is set.
        // All interrupts are masked in debug mode
        interrupt_global_enable = (~debug_mode_q)
                                // interrupts are enabled during single step or we are not stepping
                                & (~dcsr_q.step | dcsr_q.stepie)
                                & ((mstatus_q.mie & (priv_lvl_o == riscv::PRIV_LVL_M))
                                | (priv_lvl_o != riscv::PRIV_LVL_M));

        if (interrupt_cause[63] && interrupt_global_enable) begin
            // we can set the cause here
            csr_exception_o.cause = interrupt_cause;
            // However, if bit i in mideleg is set, interrupts are considered to be globally enabled if the hart’s current privilege
            // mode equals the delegated privilege mode (S or U) and that mode’s interrupt enable bit
            // (SIE or UIE in mstatus) is set, or if the current privilege mode is less than the delegated privilege mode.
            if (mideleg_q[interrupt_cause[5:0]]) begin
                if ((mstatus_q.sie && priv_lvl_o == riscv::PRIV_LVL_S) || priv_lvl_o == riscv::PRIV_LVL_U)
                    csr_exception_o.valid = 1'b1;
            end else begin
                csr_exception_o.valid = 1'b1;
            end
        end

        // -----------------
        // Privilege Check
        // -----------------
        // if we are reading or writing, check for the correct privilege level
        if (csr_we || csr_read) begin
            if ((riscv::priv_lvl_t'(priv_lvl_o & csr_addr.csr_decode.priv_lvl) != csr_addr.csr_decode.priv_lvl)) begin
                csr_exception_o.cause = riscv::ILLEGAL_INSTR;
                csr_exception_o.valid = 1'b1;
            end
            // check access to debug mode only CSRs
            if (csr_addr_i[11:4] == 8'h7b && !debug_mode_q) begin
                csr_exception_o.cause = riscv::ILLEGAL_INSTR;
                csr_exception_o.valid = 1'b1;
            end
        end
        // we got an exception in one of the processes above
        // throw an illegal instruction exception
        if (update_access_exception || read_access_exception) begin
            csr_exception_o.cause = riscv::ILLEGAL_INSTR;
            // we don't set the tval field as this will be set by the commit stage
            // this spares the extra wiring from commit to CSR and back to commit
            csr_exception_o.valid = 1'b1;
        end
        // -------------------
        // Wait for Interrupt
        // -------------------
        // if there is any interrupt pending un-stall the core
        // also un-stall if we want to enter debug mode
        if (|mip_q || debug_req_i) begin
            wfi_d = 1'b0;
        // or alternatively if there is no exception pending and we are not in debug mode wait here for the interrupt
        end else if (!debug_mode_q && csr_op_i == WFI && !ex_i.valid) begin
            wfi_d = 1'b1;
        end
    end

    // output assignments dependent on privilege mode
    always_comb begin : priv_output
        trap_vector_base_o = {mtvec_q[63:2], 2'b0};
        // output user mode stvec
        if (trap_to_priv_lvl == riscv::PRIV_LVL_S) begin
            trap_vector_base_o = {stvec_q[63:2], 2'b0};
        end

        // if we are in debug mode jump to a specific address
        if (debug_mode_q) begin
            trap_vector_base_o = dm::ExceptionAddress;
        end

        // check if we are in vectored mode, if yes then do BASE + 4 * cause
        // we are imposing an additional alignment-constraint of 64 * 4 bytes since
        // we want to spare the costly addition
        if ((mtvec_q[0] || stvec_q[0]) && csr_exception_o.cause[63]) begin
            trap_vector_base_o[7:2] = csr_exception_o.cause[5:0];
        end

        epc_o = mepc_q;
        // we are returning from supervisor mode, so take the sepc register
        if (sret) begin
            epc_o = sepc_q;
        end
        // we are returning from debug mode, to take the dpc register
        if (dret) begin
            epc_o = dpc_q;
        end
    end

    // calculate the next PC based on the current one
    always_comb begin : next_pc_calc
        automatic logic [63:0] pc;
        automatic logic [63:0] branch_target;
        automatic logic branch_taken;
        automatic logic is_compressed;
        // we only need to check the 0th instruction as in single-step mode we are only retiring one instruction
        pc = commit_instr_i[0].pc;
        branch_taken = commit_instr_i[0].bp.valid & commit_instr_i[0].bp.predict_taken;
        is_compressed = commit_instr_i[0].is_compressed;
        branch_target = commit_instr_i[0].bp.predict_address;
        // TODO(zarubaf) this adder can potentially be saved, the next address has been
        // calculated a couple of times down the pipeline
        next_pc = (branch_taken ? branch_target : (is_compressed ? pc + 'h2 : pc + 'h4));
    end

    // -------------------
    // Output Assignments
    // -------------------
    assign csr_rdata_o      = csr_rdata;
    // in debug mode we execute with privilege level M
    assign priv_lvl_o       = (debug_mode_q) ? riscv::PRIV_LVL_M : priv_lvl_q;
    // FPU outputs
    assign fflags_o         = fcsr_q.fflags;
    assign frm_o            = fcsr_q.frm;
    // MMU outputs
    assign satp_ppn_o       = satp_q.ppn;
    assign asid_o           = satp_q.asid[ASID_WIDTH-1:0];
    assign sum_o            = mstatus_q.sum;
    // we support bare memory addressing and SV39
    assign en_translation_o = (satp_q.mode == 4'h8 && priv_lvl_o != riscv::PRIV_LVL_M) ? 1'b1 : 1'b0;
    assign mxr_o            = mstatus_q.mxr;
    assign tvm_o            = mstatus_q.tvm;
    assign tw_o             = mstatus_q.tw;
    assign tsr_o            = mstatus_q.tsr;
    assign halt_csr_o       = wfi_q;
    assign icache_en_o      = icache_q[0] & (~debug_mode_q);
    assign dcache_en_o      = dcache_q[0];
    // determine if mprv needs to be considered if in debug mode
    assign mprv             = (debug_mode_q && !dcsr_q.mprven) ? 1'b0 : mstatus_q.mprv;
    assign debug_mode_o     = debug_mode_q;
    assign single_step_o    = dcsr_q.step;

    // sequential process
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            priv_lvl_q             <= riscv::PRIV_LVL_M;
            // floating-point registers
            fcsr_q                 <= 64'b0;
            // debug signals
            debug_mode_q           <= 1'b0;
            dcsr_q                 <= '0;
            dcsr_q.prv             <= riscv::PRIV_LVL_M;
            dpc_q                  <= 64'b0;
            dscratch0_q            <= 64'b0;
            // machine mode registers
            mstatus_q              <= 64'b0;
            // set to boot address + direct mode + 4 byte offset which is the initial trap
            mtvec_rst_load_q       <= 1'b1;
            mtvec_q                <= '0;
            medeleg_q              <= 64'b0;
            mideleg_q              <= 64'b0;
            mip_q                  <= 64'b0;
            mie_q                  <= 64'b0;
            mepc_q                 <= 64'b0;
            mcause_q               <= 64'b0;
            mscratch_q             <= 64'b0;
            mtval_q                <= 64'b0;
            dcache_q               <= 64'b1;
            icache_q               <= 64'b1;
            // supervisor mode registers
            sepc_q                 <= 64'b0;
            scause_q               <= 64'b0;
            stvec_q                <= 64'b0;
            sscratch_q             <= 64'b0;
            stval_q                <= 64'b0;
            satp_q                 <= 64'b0;
            // timer and counters
            cycle_q                <= 64'b0;
            instret_q              <= 64'b0;
            // aux registers
            en_ld_st_translation_q <= 1'b0;
            // wait for interrupt
            wfi_q                  <= 1'b0;
        end else begin
            priv_lvl_q             <= priv_lvl_d;
            // floating-point registers
            fcsr_q                 <= fcsr_d;
            // debug signals
            debug_mode_q           <= debug_mode_d;
            dcsr_q                 <= dcsr_d;
            dpc_q                  <= dpc_d;
            dscratch0_q            <= dscratch0_d;
            // machine mode registers
            mstatus_q              <= mstatus_d;
            mtvec_rst_load_q       <= 1'b0;
            mtvec_q                <= mtvec_d;
            medeleg_q              <= medeleg_d;
            mideleg_q              <= mideleg_d;
            mip_q                  <= mip_d;
            mie_q                  <= mie_d;
            mepc_q                 <= mepc_d;
            mcause_q               <= mcause_d;
            mscratch_q             <= mscratch_d;
            mtval_q                <= mtval_d;
            dcache_q               <= dcache_d;
            icache_q               <= icache_d;
            // supervisor mode registers
            sepc_q                 <= sepc_d;
            scause_q               <= scause_d;
            stvec_q                <= stvec_d;
            sscratch_q             <= sscratch_d;
            stval_q                <= stval_d;
            satp_q                 <= satp_d;
            // timer and counters
            cycle_q                <= cycle_d;
            instret_q              <= instret_d;
            // aux registers
            en_ld_st_translation_q <= en_ld_st_translation_d;
            // wait for interrupt
            wfi_q                  <= wfi_d;
        end
    end

    //-------------
    // Assertions
    //-------------
    `ifndef SYNTHESIS
    `ifndef VERILATOR
        // check that eret and ex are never valid together
        assert property (
          @(posedge clk_i) !(eret_o && ex_i.valid))
        else begin $error("eret and exception should never be valid at the same time"); $stop(); end
    `endif
    `endif
endmodule
