// tb_iss_axil.sv
`timescale 1ns/1ps


import "DPI-C" context function void iss_init      (input string elf);
import "DPI-C" context function void iss_step      ();
import "DPI-C" context function void iss_get_req   (output int addr,
                                                    output int wdata,
                                                    output int write);
import "DPI-C" context function void iss_set_read_data (input int rdata);
import "DPI-C" context function void iss_ack_write_and_advance();
import "DPI-C" context function void iss_finish    ();
import "DPI-C" context function bit iss_halted     ();

// ---------------------------------------------------------
// AXI-Lite interface definition (32-bit data, 32-bit addr)
// ---------------------------------------------------------
interface axi_lite_if (input logic ACLK, input logic ARESETn);

    logic [31:0] AWADDR;
    logic AWVALID;
    logic AWREADY;

    logic [31:0] WDATA;
    logic [3:0] WSTRB;
    logic WVALID;
    logic WREADY;

    logic [1:0] BRESP;
    logic BVALID;
    logic BREADY;

    logic [31:0] ARADDR;
    logic ARVALID;
    logic ARREADY;

    logic [31:0] RDATA;
    logic RVALID;
    logic RREADY;
    // RRESP is the response field on the read-data
    // channel (RDATA/RVALID/RREADY/RRESP) of AXI-Lite.
    // the AXI-lite slave drives RRESP signal and tells
    // the master whether the read succeeded and, if not,
    // what kind of fault occurred.
    //
    // Basic usage rules:
    // 
    // 1.Slave drives RRESP together with RDATA and RVALID.
    // It must remain stable until the master asserts RREADY=1 and the
    // handshake completes.
    //
    // 2. Master must sample RRESP when it also samples the data.
    //
    // If OKAY, it can trust RDATA.
    //
    // If SLVERR/DECERR, it must treat RDATA as undefined and take its
    // own recovery action (interrupt, abort, retry, etc.).
    //
    logic [2:0] RRESP;

    task automatic init();
        AWADDR  = '0;  AWVALID = 0;  AWREADY = 0;
        WDATA   = '0;  WSTRB   = '0; WVALID  = 0;  WREADY = 0;
        BRESP   = '0;  BVALID  = 0;  BREADY  = 0;

        ARADDR  = '0;  ARVALID = 0;  ARREADY = 0;
        RDATA   = '0;  RRESP   = '0; RVALID  = 0;  RREADY = 0;
    endtask

endinterface


//-------------------------------------------------
//  Very-tiny AXI-Lite slave = 2 registers
//-------------------------------------------------
module gpio_axil_slave (axi_lite_if bus, input logic ARESETn);

    logic [31:0] reg_data, reg_dir;

    // write address
    always_ff @(posedge bus.ACLK or negedge ARESETn) begin
        if(!ARESETn) begin
            bus.AWREADY     <= 0;
        end else begin
            // For every write transaction the master presents AWVALID=1 together
            // with a stable address.
            // The slave must generate a single-cycle pulse on
            // AWREADY to accept that address.
            // Here, AWREADY is high for exactly one clock whenever a new
            // address handshake is required—precisely what an AXI-Lite slave needs.
            bus.AWREADY     <= ~bus.AWREADY & bus.AWVALID;
        end
    end

    // write data
    always_ff @(posedge bus.ACLK or negedge ARESETn) begin
        if(!ARESETn) begin
            bus.WREADY  <= 0;
            reg_data    <= 0;
            reg_dir     <= 0;
        end else begin
            // generate ready pulse
            bus.WREADY <= ~bus.WREADY & bus.WVALID;
            // initiate data transfer if valid handshake
            if(bus.WREADY && bus.WVALID) begin
                case (bus.AWADDR[3:0])
                4'h0: reg_data  <= bus.WDATA;
                4'h4: reg_dir   <= bus.WDATA;
                endcase
            end
        end
    end

    // write response
    // AXI-Lite rules on write responses
    // rule 1. The slave must assert BVALID only after it has accepted both the address and the data.
    // rule 2. BVALID can stay high until the master pulses BREADY.
    // rule 3. BRESP=2’b00 (OKAY) is legal for all successful writes.
    always_ff @(posedge bus.ACLK or negedge ARESETn) begin
        if(!ARESETn) begin
            bus.BVALID <= 0; // no response during reset
            bus.BRESP <= 0;  // "OKAY" response code
        end else begin
            //------------------------------------------------------------------
            // 1.  Issue a response once the slave has accepted
            //     • the write address  (AWVALID & AWREADY)
            //     • the write data     (WVALID  & WREADY)
            //     in the same clock cycle.
            //
            // Requiring the address and data handshakes to occur in the same cycle
            // (AWREADY&AWVALID & WREADY&WVALID) is acceptable for a single-beat,
            // single-thread slave. In a more general AXI-Lite implementation you
            // might:
            //
            // - Accept address and data in different cycles, storing them in local
            // registers.
            //
            // - Assert BVALID once both have been seen (even if not
            // simultaneous).
            //------------------------------------------------------------------
            if(bus.AWVALID && bus.AWREADY && bus.WVALID && bus.WREADY)
                bus.BVALID <= 1'b1; // raise BVALID → tell master “write done”
            //------------------------------------------------------------------
            // 2.  De-assert BVALID after master acknowledges with BREADY.
            //------------------------------------------------------------------
            else if(bus.BREADY)
                bus.BVALID <= 1'b0;
        end
    end

    // read address handshake
    always_ff @(posedge bus.ACLK or negedge ARESETn) begin
        if(!ARESETn) begin
            bus.ARREADY <= 1'b0;
        end else begin
            bus.ARREADY <= ~bus.ARREADY & bus.ARVALID;
        end
    end

    // read data channel
    always_ff @(posedge bus.ACLK or negedge ARESETn) begin
        if(!ARESETn) begin
            bus.RDATA <= 0;
            bus.RVALID <= 0;
            bus.RRESP <= 0;
        end else begin
            // -----------------------------------------------------------
            // Address handshake completed this cycle (ARVALID & ARREADY)
            // -----------------------------------------------------------
            if(bus.ARVALID && bus.ARREADY) begin
                case (bus.ARADDR[3:0])
                4'h0: begin
                    bus.RDATA <= reg_data;
                    // RRESP is set in the same clock where we capture the address so
                    // it is valid/stable while RVALID is high.
                    bus.RRESP <= 2'b00;                 // OKAY
                end
                4'h4: begin
                    bus.RDATA <= reg_dir;
                    bus.RRESP <= 2'b00;                 // OKAY
                end

                default: begin                          // invalid offset
                    bus.RDATA <= 32'hDEADBEEF;
                    // The default branch returns DECERR (2'b11) for out-of-range reads,
                    // which is the recommended AXI-Lite behaviour for an address decode
                    // error.
                    bus.RRESP <= 2'b11;                 // DECERR
                end
                endcase
                bus.RVALID <= 1'b1;
                // -----------------------------------------------------------
                // Master has accepted the read data
                // -----------------------------------------------------------
            end else if(bus.RVALID && bus.RREADY) begin
                bus.RVALID <= 0; // drop valid
                // Optional: reset RRESP to 0 so next read starts clean
                bus.RRESP  <= 2'b00;
            end
        end
    end

endmodule


//-------------------------------------------------
//  AXI-Lite master helper tasks (SV drives DUT)
//-------------------------------------------------
module tb;

logic rst_n = 0;
logic clk = 0; always #5 clk = ~clk;
// cycle counter
int unsigned cycle = 0;
always @(posedge clk) cycle++;

axi_lite_if M (.ACLK(clk), .ARESETn(rst_n)); // connect clk/rst_n to AXI interface

// instantiate dut
gpio_axil_slave dut(.bus(M), .ARESETn(rst_n));


// Single-beat AXI-Lite WRITE with BRESP check, early BREADY, and timeouts.
// Returns 'ok' = 1 on OKAY response; 0 on error/timeout.
// 'timeout_cycles' = 0 disables timeouts.
// Optional 'wstrb' lets you control byte enables (default 4'hF).
task automatic axil_write (
    input  int              addr,
    input  int              data,
    output bit              ok,
    input  int unsigned     timeout_cycles = 1000,
    input  logic [3:0]      wstrb = 4'hF
);
    // Declarations must precede statements
    // they are variables not signals, so only blocking assignments are allowed
    int unsigned guard = 0;
    bit data_done = 0;
    bit addr_done = 0;

    // init ok
    ok = 0;

    // Pre-assert BREADY so we accept the response as soon as it arrives
    M.BREADY <= 1'b1;

    // Drive address & data channels
    @(posedge clk);
    M.AWADDR    <= addr;
    M.AWVALID   <= 1'b1;
    M.WDATA     <= data;
    M.WVALID    <= 1'b1;
    M.WSTRB     <= wstrb;

    // ---- Wait for AWREADY and WREADY (with optional timeout) ----
    while(!(data_done && addr_done)) begin
        if(timeout_cycles && ++guard > timeout_cycles) begin
            $error("AXI-Lite WRITE handshake timeout @0x%08x (AW=%0b W=%0b)",
                addr, addr_done, data_done);
            M.AWVALID   <= 1'b0;
            M.WVALID    <= 1'b0;
            M.BREADY    <= 1'b0;
        end
        @(posedge clk);
        if(!addr_done && M.AWREADY) addr_done = 1'b1;
        if(!data_done && M.WREADY) data_done = 1'b1;
    end

    // Deassert valids after respective handshakes (one or both may already be done)
    @(posedge clk);
    if (M.AWVALID) M.AWVALID <= 1'b0;
    if (M.WVALID ) M.WVALID  <= 1'b0;


    // ---- Wait for write response (BVALID), then check BRESP ----
    guard = 0;
    while(!M.BVALID) begin
        if(timeout_cycles && ++guard > timeout_cycles) begin
            $error("AXI-Lite WRITE response (BVALID) timeout @0x%08x", addr);
            M.BREADY <= 1'b0;
            return;
        end
    end

    // Handshake occurs with BVALID & BREADY both 1 in this cycle
    if(M.BRESP == 2'b00) begin
        ok = 1'b1;
    end else begin
        ok = 1'b0;
        $error("AXI-Lite WRITE error @0x%08x: BRESP=%b (data=0x%08x)",
            addr, M.BRESP, data);
    end

    // Drop BREADY in the next cycle
    @(posedge clk);
    M.BREADY <= 1'b0;

endtask


// Single-beat AXI-Lite read with early RREADY, RRESP check, and timeouts.
// Returns 'ok' = 1 on OKAY response; 0 on error/timeout.
// 'timeout_cycles' = 0 disables timeouts.
// The task is blocking: the caller doesn’t resume until
// the read has completed and data is assigned.
task automatic axil_read (
    input int           addr,
    output int          data,
    output bit          ok,
    input unsigned      timeout_cycles = 10000
);
    int unsigned guard = 0;
    ok = 0;
    data = '0;

    // Pre-assert RREADY to accept data as soon as it is available
    M.RREADY <= 1'b1;

    // Address phase
    @(posedge clk);
    M.ARADDR <= addr;
    M.ARVALID <= 1'b1;

    // wait for ARREADY
    while(!M.ARREADY) begin
        if(timeout_cycles && ++guard > timeout_cycles) begin
            $error("AXI-Lite READ ARREADY timeout @0x%08x", addr);
            M.ARADDR <= 0;
            M.ARVALID <= 0;
            return;
        end
        @(posedge clk);  // advance time
    end

    // deassert ARVALID after handshake
    M.ARVALID <= 1'b0;

    // Data phase
    @(posedge clk);
    guard = 0; // reset guard
    // wait for RVALID
    while(!M.RVALID) begin
        if(timeout_cycles && ++guard > timeout_cycles) begin
            $error("AXI-Lite READ RVALID timeout @0x%08x", addr);
            M.RREADY <= 1'b0;
            return;
        end
        @(posedge clk);  // advance time
    end

    // Handshake occurs with RVALID&RREADY=1 in this cycle
    data = M.RDATA;
    // check response code
    if(M.RRESP == 2'b00) begin
        ok = 1'b1;
    end else begin
        ok = 1'b0;
        $error("AXI-Lite READ error @0x%08x: RRESP=%b (data=0x%08x)", addr, M.RRESP, M.RDATA);
    end

    // Drop RREADY in the next cycle
    @(posedge clk);
    M.RREADY <= 1'b0;

endtask

//-------------------------------------------------
// Main testbench loop: run ISS and serve MMIO
//-------------------------------------------------

initial begin
  $dumpfile("waves.vcd");
  $dumpvars(0, tb);
end

typedef enum logic [1:0] { S_IDLE, S_WR, S_RD } svc_state_t;
typedef enum logic [1:0] { M_IDLE, M_RD, M_WR } mode_t;

initial begin

    int s_addr, s_wdata, s_rdata;
    static mode_t mode = M_IDLE;
    bit ok;
    static svc_state_t state = S_IDLE;

    // reset
    rst_n = 1'b0;
    M.init();
    repeat(3) @(posedge clk);
    rst_n = 1'b1;

    iss_init("fw.bin");

    // ensure we don't step in the same delta-cycle as init
    @(posedge clk);

    $display("[TB] entering main loop after reset deassert");

    forever begin

        // If ISS is halted and we're idle, finish the sim cleanly.
        if (iss_halted()) begin
            $display("[%0t | C%0d] ISS halted; no pending requests. Finishing.",
                    $time, cycle);
            iss_finish();   // optional DPI clean-up
            $finish;
        end

        // executes 1 instruction
        iss_step();

        // Always fetch current request; you can still check a flag if you want
        iss_get_req(s_addr, s_wdata, mode);

        if (mode == M_WR) begin
            axil_write(s_addr, s_wdata, ok);
            iss_ack_write_and_advance();
        end else if(mode == M_RD) begin
            axil_read(s_addr, s_rdata, ok);
            iss_set_read_data(s_rdata);       // sets resp_ready and clears req_valid
        end

        @(posedge clk);
    end

    iss_finish();
    $finish;
end

endmodule
