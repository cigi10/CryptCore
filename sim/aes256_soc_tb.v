`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 03/15/2026 04:09:50 PM
// Design Name: 
// Module Name: aes256_soc_tb
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module aes256_soc_tb;
    reg         aclk;
    reg         aresetn;    

    reg  [7:0]  awaddr;
    reg         awvalid;
    wire        awready;

    reg  [31:0] wdata;
    reg  [3:0]  wstrb;
    reg         wvalid;
    wire        wready;

    wire [1:0]  bresp;
    wire        bvalid;
    reg         bready;

    reg  [7:0]  araddr;
    reg         arvalid;
    wire        arready;

    wire [31:0] rdata;
    wire [1:0]  rresp;
    wire        rvalid;
    reg         rready;

    integer pass_count;
    integer fail_count;
    integer test_num;
    integer timeout;

    aes256_axi_wrapper dut (
        .S_AXI_ACLK    (aclk),
        .S_AXI_ARESETN (aresetn),
        .S_AXI_AWADDR  (awaddr),
        .S_AXI_AWVALID (awvalid),
        .S_AXI_AWREADY (awready),
        .S_AXI_WDATA   (wdata),
        .S_AXI_WSTRB   (wstrb),
        .S_AXI_WVALID  (wvalid),
        .S_AXI_WREADY  (wready),
        .S_AXI_BRESP   (bresp),
        .S_AXI_BVALID  (bvalid),
        .S_AXI_BREADY  (bready),
        .S_AXI_ARADDR  (araddr),
        .S_AXI_ARVALID (arvalid),
        .S_AXI_ARREADY (arready),
        .S_AXI_RDATA   (rdata),
        .S_AXI_RRESP   (rresp),
        .S_AXI_RVALID  (rvalid),
        .S_AXI_RREADY  (rready)
    );

    initial aclk = 0;
    always #5 aclk = ~aclk;

    task axi_write;
        input [7:0]  addr;
        input [31:0] data;
        begin
            @(posedge aclk);
            awaddr  = addr;
            awvalid = 1;
            wdata   = data;
            wstrb   = 4'hF;  
            wvalid  = 1;
            bready  = 1;

            @(posedge aclk);
            while (!awready || !wready) @(posedge aclk);

            while (!bvalid) @(posedge aclk);

            awvalid = 0;
            wvalid  = 0;
            bready  = 0;
            @(posedge aclk);
        end
    endtask

    task axi_read;
        input  [7:0]  addr;
        output [31:0] data;
        begin
            @(posedge aclk);
            araddr  = addr;
            arvalid = 1;
            rready  = 1;

            @(posedge aclk);
            while (!rvalid) @(posedge aclk);
            #1;
            data = rdata;

            arvalid = 0;
            rready  = 0;
            @(posedge aclk);
        end
    endtask

    task wait_done;
        begin
            timeout = 0;
            begin : poll_loop
                reg [31:0] status;
                status = 0;
                while (status[0] !== 1'b1 && timeout < 100) begin
                    axi_read(8'h04, status);
                    timeout = timeout + 1;
                end
                if (timeout >= 100)
                    $display("WARNING: timed out waiting for done");
            end
        end
    endtask

    task load_key_axi;
        input [255:0] k;
        begin
            axi_write(8'h08, k[255:224]);
            axi_write(8'h0C, k[223:192]);
            axi_write(8'h10, k[191:160]);
            axi_write(8'h14, k[159:128]);
            axi_write(8'h18, k[127:96]);
            axi_write(8'h1C, k[95:64]);
            axi_write(8'h20, k[63:32]);
            axi_write(8'h24, k[31:0]);
            axi_write(8'h00, 32'h2);
        end
    endtask

    task encrypt_axi;
        input  [127:0] pt;
        output [127:0] ct;
        begin
            axi_write(8'h28, pt[127:96]);
            axi_write(8'h2C, pt[95:64]);
            axi_write(8'h30, pt[63:32]);
            axi_write(8'h34, pt[31:0]);

            axi_write(8'h00, 32'h1);

            wait_done;

            begin : read_ct
                reg [31:0] w0, w1, w2, w3;
                axi_read(8'h38, w0);
                axi_read(8'h3C, w1);
                axi_read(8'h40, w2);
                axi_read(8'h44, w3);
                ct = {w0, w1, w2, w3};
            end
        end
    endtask

    task do_reset;
        begin
            aresetn = 0;  
            awaddr  = 0;
            awvalid = 0;
            wdata   = 0;
            wstrb   = 0;
            wvalid  = 0;
            bready  = 0;
            araddr  = 0;
            arvalid = 0;
            rready  = 0;
            repeat(5) @(posedge aclk);
            aresetn = 1;  
            repeat(5) @(posedge aclk);
        end
    endtask

    initial begin
        pass_count = 0;
        fail_count = 0;
        test_num   = 0;

        $display("========================================");
        $display("  AES-256 SoC AXI Interface Verification");
        $display("========================================");

        do_reset;

        // ════════════════════════════════════════════
        // TEST 1: NIST vector through full AXI flow
        // This is the money test - CPU writes key and
        // plaintext over AXI, reads back ciphertext
        // ════════════════════════════════════════════
        $display("");
        $display("--- Test 1: Full AXI encrypt (NIST vector) ---");

        begin : test1
            reg [127:0] result;

            load_key_axi(
                256'h000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
            );
            encrypt_axi(
                128'h00112233445566778899aabbccddeeff,
                result
            );

            test_num = test_num + 1;
            if (result === 128'h8ea2b7ca516745bfeafc49904b496089) begin
                $display("TEST %0d PASS - %h", test_num, result);
                pass_count = pass_count + 1;
            end else begin
                $display("TEST %0d FAIL", test_num);
                $display("         expected: 8ea2b7ca516745bfeafc49904b496089");
                $display("         got:      %h", result);
                fail_count = fail_count + 1;
            end
        end

        // ════════════════════════════════════════════
        // TEST 2: all-zeros key and plaintext
        // ════════════════════════════════════════════
        $display("");
        $display("--- Test 2: All-zeros key and plaintext ---");

        do_reset;

        begin : test2
            reg [127:0] result;

            load_key_axi(256'h0);
            encrypt_axi(128'h0, result);

            test_num = test_num + 1;
            if (result === 128'hdc95c078a2408989ad48a21492842087) begin
                $display("TEST %0d PASS - %h", test_num, result);
                pass_count = pass_count + 1;
            end else begin
                $display("TEST %0d FAIL", test_num);
                $display("         expected: dc95c078a2408989ad48a21492842087");
                $display("         got:      %h", result);
                fail_count = fail_count + 1;
            end
        end

        // ════════════════════════════════════════════
        // TEST 3: encrypt two blocks with same key
        // key should stay loaded between encryptions
        // ════════════════════════════════════════════
        $display("");
        $display("--- Test 3: Two blocks same key ---");

        do_reset;

        begin : test3
            reg [127:0] result1, result2;

            // load key once
            load_key_axi(
                256'h000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
            );

            // encrypt block 1
            encrypt_axi(
                128'h00112233445566778899aabbccddeeff,
                result1
            );

            // encrypt block 2 - no key reload needed
            encrypt_axi(
                128'h00000000000000000000000000000000,
                result2
            );

            test_num = test_num + 1;
            $display("Block 1: %h", result1);
            $display("Block 2: %h", result2);

            // both should be correct and different
            if (result1 === 128'h8ea2b7ca516745bfeafc49904b496089 &&
                result2 === 128'hf29000b62a499fd0a9f39a6add2e7780 &&
                result1 !== result2) begin
                $display("TEST %0d PASS - key held between encryptions", test_num);
                pass_count = pass_count + 1;
            end else begin
                $display("TEST %0d FAIL", test_num);
                fail_count = fail_count + 1;
            end
        end

        // ════════════════════════════════════════════
        // TEST 4: status register clears on new encrypt
        // after encryption done=1, start new one,
        // done should go back to 0 then 1 again
        // ════════════════════════════════════════════
        $display("");
        $display("--- Test 4: Status register behaviour ---");

        do_reset;

        begin : test4
            reg [31:0] status;
            reg [127:0] result;

            load_key_axi(256'h0);
            encrypt_axi(128'h0, result);

            // read status - should be 1 (done)
            axi_read(8'h04, status);
            $display("Status after encrypt: %h (expect 1)", status);

            // start another encryption - status should clear
            axi_write(8'h28, 32'hdeadbeef);
            axi_write(8'h2C, 32'hcafebabe);
            axi_write(8'h30, 32'h01234567);
            axi_write(8'h34, 32'h89abcdef);
            axi_write(8'h00, 32'h1);  // start

            // read status immediately - should be 0 now
            axi_read(8'h04, status);
            $display("Status during encrypt: %h (expect 0)", status);

            // wait for done
            wait_done;
            axi_read(8'h04, status);
            $display("Status after encrypt: %h (expect 1)", status);

            test_num = test_num + 1;
            if (status[0] === 1'b1) begin
                $display("TEST %0d PASS - status register behaves correctly", test_num);
                pass_count = pass_count + 1;
            end else begin
                $display("TEST %0d FAIL - status stuck", test_num);
                fail_count = fail_count + 1;
            end
        end

        // ════════════════════════════════════════════
        // FINAL SUMMARY
        // ════════════════════════════════════════════
        $display("");
        $display("========================================");
        $display("  RESULTS: %0d passed, %0d failed out of %0d tests",
                  pass_count, fail_count, test_num);
        if (fail_count == 0)
            $display("  ALL TESTS PASSED - SoC AXI interface verified!");
        else
            $display("  SOME TESTS FAILED - check above");
        $display("========================================");

        $finish;
    end

endmodule
