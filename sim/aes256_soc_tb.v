`timescale 1ns / 1ps
// ============================================================================
// aes256_soc_tb.v  -  AES-256 AXI4-Lite Wrapper Testbench
//
// Root cause of SoC timeout:
//   The AES-256 key schedule takes 52 clock cycles to complete after
//   key_valid is pulsed.  The original TB called encrypt_axi() immediately
//   after load_key_axi(), but the pipeline gates valid_in with key_ready,
//   so the block was silently dropped → valid_out never came → timeout.
//
// Fix:
//   STATUS register bit 1 now reflects key_ready (added to wrapper).
//   load_key_axi() polls STATUS[1] until key_ready before returning.
//   encrypt_axi() therefore never fires until the key schedule is done.
// ============================================================================

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

    // -------------------------------------------------------------------------
    // Task: AXI4-Lite write
    // -------------------------------------------------------------------------
    task axi_write;
        input [7:0]  addr;
        input [31:0] data;
        begin
            @(posedge aclk); #1;
            awaddr  = addr;
            awvalid = 1;
            wdata   = data;
            wstrb   = 4'hF;
            wvalid  = 1;
            bready  = 1;

            @(posedge aclk);
            while (!(awready && awvalid) || !(wready && wvalid))
                @(posedge aclk);

            #1;
            awvalid = 0;
            wvalid  = 0;

            while (!bvalid) @(posedge aclk);
            #1;
            bready = 0;
            @(posedge aclk);
        end
    endtask

    // -------------------------------------------------------------------------
    // Task: AXI4-Lite read
    // -------------------------------------------------------------------------
    task axi_read;
        input  [7:0]  addr;
        output [31:0] data;
        begin
            @(posedge aclk); #1;
            araddr  = addr;
            arvalid = 1;
            rready  = 1;

            @(posedge aclk);
            while (!rvalid) @(posedge aclk);
            #1;
            data    = rdata;
            arvalid = 0;
            rready  = 0;
            @(posedge aclk);
        end
    endtask

    // -------------------------------------------------------------------------
    // Task: poll STATUS[0] (done) until set
    // -------------------------------------------------------------------------
    task wait_done;
        begin
            timeout = 0;
            begin : poll_done
                reg [31:0] status;
                status = 32'h0;
                while (status[0] !== 1'b1 && timeout < 300) begin
                    axi_read(8'h04, status);
                    timeout = timeout + 1;
                end
                if (timeout >= 300)
                    $display("WARNING: timed out waiting for STATUS[0]=done");
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Task: poll STATUS[1] (key_ready) until set
    // Key schedule takes 52 cycles; each AXI read ~4 cycles → 20 polls enough,
    // but we use 100 for margin.
    // -------------------------------------------------------------------------
    task wait_key_ready;
        begin
            timeout = 0;
            begin : poll_key
                reg [31:0] status;
                status = 32'h0;
                while (status[1] !== 1'b1 && timeout < 100) begin
                    axi_read(8'h04, status);
                    timeout = timeout + 1;
                end
                if (timeout >= 100)
                    $display("WARNING: timed out waiting for STATUS[1]=key_ready");
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Task: full reset
    // -------------------------------------------------------------------------
    task do_reset;
        begin
            aresetn = 1'b0;
            awaddr  = 8'h0;  awvalid = 1'b0;
            wdata   = 32'h0; wstrb   = 4'h0; wvalid  = 1'b0;
            bready  = 1'b0;
            araddr  = 8'h0;  arvalid = 1'b0;
            rready  = 1'b0;
            repeat(8) @(posedge aclk);
            aresetn = 1'b1;
            repeat(8) @(posedge aclk);
        end
    endtask

    // -------------------------------------------------------------------------
    // Task: write key registers + pulse CTRL bit1, then WAIT for key_ready
    // This is the critical fix: we block here until the key schedule finishes.
    // -------------------------------------------------------------------------
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
            axi_write(8'h00, 32'h00000002);  // bit1 = load_key
            // Block until key schedule is done before returning
            wait_key_ready;
        end
    endtask

    // -------------------------------------------------------------------------
    // Task: write plaintext, start, poll done, read ciphertext
    // -------------------------------------------------------------------------
    task encrypt_axi;
        input  [127:0] pt;
        output [127:0] ct;
        begin
            axi_write(8'h28, pt[127:96]);
            axi_write(8'h2C, pt[95:64]);
            axi_write(8'h30, pt[63:32]);
            axi_write(8'h34, pt[31:0]);
            axi_write(8'h00, 32'h00000001);  // bit0 = start
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

    // =========================================================================
    initial begin
        pass_count = 0;
        fail_count = 0;
        test_num   = 0;

        $display("========================================");
        $display("  AES-256 SoC AXI Interface Verification");
        $display("========================================");

        do_reset;

        // ---------------------------------------------------------------------
        // TEST 1: NIST vector
        // ---------------------------------------------------------------------
        $display("");
        $display("--- Test 1: Full AXI encrypt (NIST vector) ---");

        begin : test1
            reg [127:0] result;
            load_key_axi(256'h000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f);
            encrypt_axi(128'h00112233445566778899aabbccddeeff, result);

            test_num = test_num + 1;
            if (result === 128'h8ea2b7ca516745bfeafc49904b496089) begin
                $display("TEST %0d PASS - %032h", test_num, result);
                pass_count = pass_count + 1;
            end else begin
                $display("TEST %0d FAIL", test_num);
                $display("         expected: 8ea2b7ca516745bfeafc49904b496089");
                $display("         got     : %032h", result);
                fail_count = fail_count + 1;
            end
        end

        // ---------------------------------------------------------------------
        // TEST 2: All-zeros key and plaintext
        // ---------------------------------------------------------------------
        $display("");
        $display("--- Test 2: All-zeros key and plaintext ---");

        do_reset;

        begin : test2
            reg [127:0] result;
            load_key_axi(256'h0000000000000000000000000000000000000000000000000000000000000000);
            encrypt_axi(128'h00000000000000000000000000000000, result);

            test_num = test_num + 1;
            if (result === 128'hdc95c078a2408989ad48a21492842087) begin
                $display("TEST %0d PASS - %032h", test_num, result);
                pass_count = pass_count + 1;
            end else begin
                $display("TEST %0d FAIL", test_num);
                $display("         expected: dc95c078a2408989ad48a21492842087");
                $display("         got     : %032h", result);
                fail_count = fail_count + 1;
            end
        end

        // ---------------------------------------------------------------------
        // TEST 3: Two blocks, same key, no reload
        // ---------------------------------------------------------------------
        $display("");
        $display("--- Test 3: Two blocks, same key, no reload ---");

        do_reset;

        begin : test3
            reg [127:0] result1, result2;
            load_key_axi(256'h000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f);

            encrypt_axi(128'h00112233445566778899aabbccddeeff, result1);
            $display("Block 1 : %032h", result1);

            encrypt_axi(128'h00000000000000000000000000000000, result2);
            $display("Block 2 : %032h", result2);

            test_num = test_num + 1;
            if (result1 === 128'h8ea2b7ca516745bfeafc49904b496089 &&
                result2 === 128'hf29000b62a499fd0a9f39a6add2e7780 &&
                result1 !== result2) begin
                $display("TEST %0d PASS - key held between encryptions", test_num);
                pass_count = pass_count + 1;
            end else begin
                $display("TEST %0d FAIL", test_num);
                $display("  result1 exp: 8ea2b7ca516745bfeafc49904b496089  got: %032h", result1);
                $display("  result2 exp: f29000b62a499fd0a9f39a6add2e7780  got: %032h", result2);
                fail_count = fail_count + 1;
            end
        end

        // ---------------------------------------------------------------------
        // TEST 4: STATUS register behaviour
        // ---------------------------------------------------------------------
        $display("");
        $display("--- Test 4: STATUS register behaviour ---");

        do_reset;

        begin : test4
            reg [31:0]  status;
            reg [127:0] result;

            load_key_axi(256'h0000000000000000000000000000000000000000000000000000000000000000);
            encrypt_axi(128'h00000000000000000000000000000000, result);

            axi_read(8'h04, status);
            $display("Status after 1st encrypt   : done=%0b key_ready=%0b (expect 1 1)",
                      status[0], status[1]);

            axi_write(8'h28, 32'hdeadbeef);
            axi_write(8'h2C, 32'hcafebabe);
            axi_write(8'h30, 32'h01234567);
            axi_write(8'h34, 32'h89abcdef);
            axi_write(8'h00, 32'h00000001);

            axi_read(8'h04, status);
            $display("Status during 2nd encrypt  : done=%0b (informational)", status[0]);

            wait_done;
            axi_read(8'h04, status);
            $display("Status after 2nd encrypt   : done=%0b (expect 1)", status[0]);

            test_num = test_num + 1;
            if (status[0] === 1'b1) begin
                $display("TEST %0d PASS - STATUS register behaves correctly", test_num);
                pass_count = pass_count + 1;
            end else begin
                $display("TEST %0d FAIL - STATUS[0] did not go high after 2nd encrypt", test_num);
                fail_count = fail_count + 1;
            end
        end

        // ---------------------------------------------------------------------
        // TEST 5: Key-change via AXI
        // ---------------------------------------------------------------------
        $display("");
        $display("--- Test 5: Key-change via AXI ---");

        do_reset;

        begin : test5
            reg [127:0] ct_k1, ct_k2;

            load_key_axi(256'h000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f);
            encrypt_axi(128'hdeadbeefcafebabe0123456789abcdef, ct_k1);
            $display("Key1 CT : %032h", ct_k1);

            do_reset;
            load_key_axi(256'hffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
            encrypt_axi(128'hdeadbeefcafebabe0123456789abcdef, ct_k2);
            $display("Key2 CT : %032h", ct_k2);

            test_num = test_num + 1;
            if (ct_k1 !== ct_k2) begin
                $display("TEST %0d PASS - different keys produce different ciphertext", test_num);
                pass_count = pass_count + 1;
            end else begin
                $display("TEST %0d FAIL - both keys produced identical ciphertext!", test_num);
                fail_count = fail_count + 1;
            end
        end

        // ---------------------------------------------------------------------
        // TEST 6: Reset clears STATUS
        // ---------------------------------------------------------------------
        $display("");
        $display("--- Test 6: Reset clears STATUS register ---");

        do_reset;

        begin : test6
            reg [31:0]  status;
            reg [127:0] result;

            load_key_axi(256'h0000000000000000000000000000000000000000000000000000000000000000);
            encrypt_axi(128'h00000000000000000000000000000000, result);

            axi_read(8'h04, status);
            $display("STATUS before reset : done=%0b (expect 1)", status[0]);

            aresetn = 1'b0;
            repeat(8) @(posedge aclk);
            aresetn = 1'b1;
            repeat(8) @(posedge aclk);

            axi_read(8'h04, status);
            $display("STATUS after  reset : done=%0b (expect 0)", status[0]);

            test_num = test_num + 1;
            if (status[0] === 1'b0) begin
                $display("TEST %0d PASS - reset cleared STATUS", test_num);
                pass_count = pass_count + 1;
            end else begin
                $display("TEST %0d FAIL - STATUS still high after reset", test_num);
                fail_count = fail_count + 1;
            end
        end

        // ---------------------------------------------------------------------
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
