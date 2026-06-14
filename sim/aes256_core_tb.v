`timescale 1ns / 1ps
// ============================================================================
// aes256_core_tb.v  -  AES-256 Pipelined Core Testbench
// ============================================================================

module aes256_core_tb;

    reg          clk;
    reg          rst;
    reg  [255:0] key;
    reg          key_valid;
    reg  [127:0] plaintext;
    reg          valid_in;
    wire [127:0] ciphertext;
    wire         valid_out;

    integer pass_count;
    integer fail_count;
    integer test_num;
    integer timeout;

    aes256_pipelined uut (
        .clk        (clk),
        .rst        (rst),
        .key        (key),
        .key_valid  (key_valid),
        .plaintext  (plaintext),
        .valid_in   (valid_in),
        .ciphertext (ciphertext),
        .valid_out  (valid_out)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Task: reset + full pipeline flush
    // -------------------------------------------------------------------------
    task do_reset;
        begin
            rst       = 1;
            key_valid = 0;
            valid_in  = 0;
            key       = 256'h0;
            plaintext = 128'h0;
            repeat(5) @(posedge clk);
            rst = 0;
            repeat(35) @(posedge clk); // flush 29-stage pipeline + margin
        end
    endtask

    // -------------------------------------------------------------------------
    // Task: load key and wait for key schedule to finish
    // AES-256 key expansion: words 0-7 loaded on key_valid, words 8-59
    // computed one per cycle (52 cycles). Wait 60 cycles for ready.
    // -------------------------------------------------------------------------
    task load_key;
        input [255:0] k;
        begin
            @(posedge clk);
            key       = k;
            key_valid = 1;
            @(posedge clk);
            key_valid = 0;
            repeat(60) @(posedge clk);
        end
    endtask

    // -------------------------------------------------------------------------
    // Task: wait for valid_out (timeout 150 cycles)
    // -------------------------------------------------------------------------
    task wait_for_output;
        output [127:0] captured_ct;
        output         timed_out;
        begin
            timeout   = 0;
            timed_out = 0;
            while (valid_out !== 1'b1 && timeout < 150) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            #1;
            if (timeout >= 150) begin
                timed_out   = 1;
                captured_ct = 128'hx;
            end else begin
                timed_out   = 0;
                captured_ct = ciphertext;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Task: encrypt one block and compare against expected ciphertext
    // -------------------------------------------------------------------------
    task encrypt_and_check;
        input [127:0] pt;
        input [127:0] expected_ct;
        begin
            plaintext = pt;
            valid_in  = 1;
            @(posedge clk);
            valid_in  = 0;
            begin : wait_block
                reg [127:0] captured;
                reg         timed_out;
                wait_for_output(captured, timed_out);
                test_num = test_num + 1;
                if (timed_out) begin
                    $display("TEST %0d FAIL - timed out waiting for valid_out", test_num);
                    $display("         plaintext : %032h", pt);
                    $display("         expected  : %032h", expected_ct);
                    fail_count = fail_count + 1;
                end else if (captured === expected_ct) begin
                    $display("TEST %0d PASS - ciphertext = %032h", test_num, captured);
                    pass_count = pass_count + 1;
                end else begin
                    $display("TEST %0d FAIL - wrong ciphertext", test_num);
                    $display("         plaintext : %032h", pt);
                    $display("         expected  : %032h", expected_ct);
                    $display("         got       : %032h", captured);
                    fail_count = fail_count + 1;
                end
            end
            repeat(35) @(posedge clk); // flush before next test
        end
    endtask

    // =========================================================================
    initial begin
        pass_count = 0;
        fail_count = 0;
        test_num   = 0;

        $display("========================================");
        $display("  AES-256 Pipelined Core Verification  ");
        $display("  Pipeline depth : 29 stages           ");
        $display("  Key sched lag  : ~52 cycles          ");
        $display("========================================");

        do_reset;

        // ---------------------------------------------------------------------
        // GROUP 1: NIST FIPS-197 Official Test Vectors
        // ---------------------------------------------------------------------
        $display("");
        $display("--- Group 1: NIST FIPS-197 Vectors ---");

        // Vector 1
        load_key(256'h000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f);
        encrypt_and_check(
            128'h00112233445566778899aabbccddeeff,
            128'h8ea2b7ca516745bfeafc49904b496089
        );

        // Vector 2: all-zero key, all-zero plaintext
        do_reset;
        load_key(256'h0000000000000000000000000000000000000000000000000000000000000000);
        encrypt_and_check(
            128'h00000000000000000000000000000000,
            128'hdc95c078a2408989ad48a21492842087
        );

        // Vector 3: all-zero key, all-ones plaintext
        do_reset;
        load_key(256'h0000000000000000000000000000000000000000000000000000000000000000);
        encrypt_and_check(
            128'hffffffffffffffffffffffffffffffff,
            128'hacdace8078a32b1a182bfa4987ca1347
        );

        // Vector 4: all-ones key, all-zero plaintext
        do_reset;
        load_key(256'hffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
        encrypt_and_check(
            128'h00000000000000000000000000000000,
            128'h4bf85f1b5d54adbc307b0a048389adcb
        );

        // ---------------------------------------------------------------------
        // GROUP 2: Key-change test
        // ---------------------------------------------------------------------
        $display("");
        $display("--- Group 2: Key Change Test ---");

        do_reset;
        load_key(256'h000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f);
        plaintext = 128'hdeadbeefcafebabe0123456789abcdef;
        valid_in  = 1;
        @(posedge clk);
        valid_in  = 0;

        begin : key_change_block
            reg [127:0] ct_key1;
            reg [127:0] ct_key2;
            reg         to1, to2;

            wait_for_output(ct_key1, to1);
            $display("Key1 ciphertext : %032h", ct_key1);

            do_reset;
            load_key(256'hffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
            plaintext = 128'hdeadbeefcafebabe0123456789abcdef;
            valid_in  = 1;
            @(posedge clk);
            valid_in  = 0;

            wait_for_output(ct_key2, to2);
            $display("Key2 ciphertext : %032h", ct_key2);

            test_num = test_num + 1;
            if (!to1 && !to2 && ct_key1 !== ct_key2) begin
                $display("TEST %0d PASS - different keys produce different output", test_num);
                pass_count = pass_count + 1;
            end else begin
                $display("TEST %0d FAIL - key change test failed (to1=%0b to2=%0b same=%0b)",
                          test_num, to1, to2, (ct_key1 === ct_key2));
                fail_count = fail_count + 1;
            end
        end

        // ---------------------------------------------------------------------
        // GROUP 3: Avalanche effect test
        // ---------------------------------------------------------------------
        $display("");
        $display("--- Group 3: Avalanche Effect Test ---");

        do_reset;
        load_key(256'h000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f);
        plaintext = 128'h00000000000000000000000000000000;
        valid_in  = 1;
        @(posedge clk);
        valid_in  = 0;

        begin : avalanche_block
            reg [127:0] ct_orig;
            reg [127:0] ct_flip;
            reg [127:0] diff;
            reg         to1, to2;
            integer     bit_diff;
            integer     j;

            wait_for_output(ct_orig, to1);
            $display("Original  PT=0x00..00 : %032h", ct_orig);

            do_reset;
            load_key(256'h000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f);
            plaintext = 128'h00000000000000000000000000000001;
            valid_in  = 1;
            @(posedge clk);
            valid_in  = 0;

            wait_for_output(ct_flip, to2);
            $display("1-bit flip PT=0x00..01: %032h", ct_flip);

            diff     = ct_orig ^ ct_flip;
            bit_diff = 0;
            for (j = 0; j < 128; j = j + 1)
                if (diff[j]) bit_diff = bit_diff + 1;

            $display("Bits that flipped: %0d / 128", bit_diff);

            test_num = test_num + 1;
            if (!to1 && !to2 && bit_diff > 48) begin
                $display("TEST %0d PASS - strong avalanche (%0d/128 bits flipped)", test_num, bit_diff);
                pass_count = pass_count + 1;
            end else begin
                $display("TEST %0d FAIL - weak avalanche (%0d/128 bits flipped)", test_num, bit_diff);
                fail_count = fail_count + 1;
            end
        end

        // ---------------------------------------------------------------------
        // GROUP 4: Reset behaviour
        // ---------------------------------------------------------------------
        $display("");
        $display("--- Group 4: Reset Behaviour Test ---");

        do_reset;
        load_key(256'h000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f);
        plaintext = 128'hdeadbeefdeadbeefdeadbeefdeadbeef;
        valid_in  = 1;
        @(posedge clk);
        valid_in  = 0;
        repeat(8) @(posedge clk);

        rst = 1;
        repeat(5) @(posedge clk);
        rst = 0;
        repeat(40) @(posedge clk);
        #1;

        test_num = test_num + 1;
        if (valid_out === 1'b0) begin
            $display("TEST %0d PASS - reset cleared pipeline, no ghost output", test_num);
            pass_count = pass_count + 1;
        end else begin
            $display("TEST %0d FAIL - valid_out high after reset!", test_num);
            fail_count = fail_count + 1;
        end

        // ---------------------------------------------------------------------
        // GROUP 5: Back-to-back throughput
        // ---------------------------------------------------------------------
        $display("");
        $display("--- Group 5: Back-to-Back Throughput Test ---");

        do_reset;
        load_key(256'h000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f);

        plaintext = 128'h00000000000000000000000000000000;
        valid_in  = 1;
        @(posedge clk);
        plaintext = 128'h11111111111111111111111111111111;
        @(posedge clk);
        plaintext = 128'h22222222222222222222222222222222;
        @(posedge clk);
        plaintext = 128'h33333333333333333333333333333333;
        @(posedge clk);
        valid_in  = 0;

        begin : throughput_block
            integer out_count;
            integer watch;
            out_count = 0;

            for (watch = 0; watch < 60; watch = watch + 1) begin
                @(posedge clk);
                #1;
                if (valid_out === 1'b1) begin
                    out_count = out_count + 1;
                    $display("Block %0d out: %032h", out_count, ciphertext);
                end
            end

            test_num = test_num + 1;
            if (out_count == 4) begin
                $display("TEST %0d PASS - all 4 blocks produced back-to-back", test_num);
                pass_count = pass_count + 1;
            end else begin
                $display("TEST %0d FAIL - only %0d/4 blocks came out", test_num, out_count);
                fail_count = fail_count + 1;
            end
        end

        // ---------------------------------------------------------------------
        // GROUP 6: Re-key and verify correctness
        // ---------------------------------------------------------------------
        $display("");
        $display("--- Group 6: Re-Key and Verify Correctness ---");

        do_reset;
        load_key(256'h000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f);
        encrypt_and_check(
            128'h00112233445566778899aabbccddeeff,
            128'h8ea2b7ca516745bfeafc49904b496089
        );

        do_reset;
        load_key(256'h0000000000000000000000000000000000000000000000000000000000000000);
        encrypt_and_check(
            128'h00000000000000000000000000000000,
            128'hdc95c078a2408989ad48a21492842087
        );

        // ---------------------------------------------------------------------
        // FINAL SUMMARY
        // ---------------------------------------------------------------------
        $display("");
        $display("========================================");
        $display("  RESULTS: %0d passed, %0d failed out of %0d tests",
                  pass_count, fail_count, test_num);
        if (fail_count == 0)
            $display("  ALL TESTS PASSED - core is verified!");
        else
            $display("  SOME TESTS FAILED - check above");
        $display("========================================");

        $finish;
    end

endmodule
