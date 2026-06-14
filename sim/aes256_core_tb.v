`timescale 1ns / 1ps

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

    // ─── Task: reset + full pipeline flush ───────────
    task do_reset;
        begin
            rst       = 1;
            key_valid = 0;
            valid_in  = 0;
            key       = 256'h0;
            plaintext = 128'h0;
            repeat(3) @(posedge clk);
            rst = 0;
            repeat(20) @(posedge clk); // flush all 15 stages
        end
    endtask

    // ─── Task: load key ──────────────────────────────
    task load_key;
        input [255:0] k;
        begin
            @(posedge clk);
            key       = k;
            key_valid = 1;
            @(posedge clk);
            key_valid = 0;
            @(posedge clk);
        end
    endtask

    // ─── Task: wait for valid_out ────────────────────
    task wait_for_output;
        output [127:0] captured_ct;
        output         timed_out;
        begin
            timeout   = 0;
            timed_out = 0;
            while (valid_out !== 1'b1 && timeout < 60) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            #1;
            if (timeout >= 60) begin
                timed_out   = 1;
                captured_ct = 128'hx;
            end else begin
                timed_out   = 0;
                captured_ct = ciphertext;
            end
        end
    endtask

    // ─── Task: encrypt and check ─────────────────────
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
                    $display("TEST %0d FAIL - timed out", test_num);
                    $display("         plaintext : %h", pt);
                    $display("         expected  : %h", expected_ct);
                    fail_count = fail_count + 1;
                end else if (captured === expected_ct) begin
                    $display("TEST %0d PASS - %h", test_num, captured);
                    pass_count = pass_count + 1;
                end else begin
                    $display("TEST %0d FAIL - wrong ciphertext", test_num);
                    $display("         plaintext : %h", pt);
                    $display("         expected  : %h", expected_ct);
                    $display("         got       : %h", captured);
                    fail_count = fail_count + 1;
                end
            end
            repeat(20) @(posedge clk); // flush before next test
        end
    endtask

    initial begin
        pass_count = 0;
        fail_count = 0;
        test_num   = 0;

        $display("========================================");
        $display("  AES-256 Pipelined Core Verification  ");
        $display("========================================");

        do_reset;

        // ════════════════════════════════════════════
        // GROUP 1: NIST FIPS-197 Official Test Vectors
        // ════════════════════════════════════════════
        $display("");
        $display("--- Group 1: NIST FIPS-197 Vectors ---");

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

        do_reset;
        load_key(256'h0000000000000000000000000000000000000000000000000000000000000000);
        encrypt_and_check(
            128'hffffffffffffffffffffffffffffffff,
            128'hacdace8078a32b1a182bfa4987ca1347
        );

        do_reset;
        load_key(256'hffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
        encrypt_and_check(
            128'h00000000000000000000000000000000,
            128'h4bf85f1b5d54adbc307b0a048389adcb
        );

        // ════════════════════════════════════════════
        // GROUP 2: Key change test
        // ════════════════════════════════════════════
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
            $display("Key1 ciphertext: %h", ct_key1);

            do_reset;
            load_key(256'hffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
            plaintext = 128'hdeadbeefcafebabe0123456789abcdef;
            valid_in  = 1;
            @(posedge clk);
            valid_in  = 0;

            wait_for_output(ct_key2, to2);
            $display("Key2 ciphertext: %h", ct_key2);

            test_num = test_num + 1;
            if (!to1 && !to2 && ct_key1 !== ct_key2) begin
                $display("TEST %0d PASS - different keys produce different output", test_num);
                pass_count = pass_count + 1;
            end else begin
                $display("TEST %0d FAIL - key change test failed", test_num);
                fail_count = fail_count + 1;
            end
        end

        // ════════════════════════════════════════════
        // GROUP 3: Avalanche effect test
        // ════════════════════════════════════════════
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
            $display("Original  PT=0x00..00: %h", ct_orig);

            do_reset;
            load_key(256'h000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f);
            plaintext = 128'h00000000000000000000000000000001;
            valid_in  = 1;
            @(posedge clk);
            valid_in  = 0;

            wait_for_output(ct_flip, to2);
            $display("1-bit flip PT=0x00..01: %h", ct_flip);

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

        // ════════════════════════════════════════════
        // GROUP 4: Reset behaviour test
        // ════════════════════════════════════════════
        $display("");
        $display("--- Group 4: Reset Behaviour Test ---");

        do_reset;
        load_key(256'h000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f);
        plaintext = 128'hdeadbeefdeadbeefdeadbeefdeadbeef;
        valid_in  = 1;
        @(posedge clk);
        valid_in  = 0;
        repeat(5) @(posedge clk);

        rst = 1;
        repeat(3) @(posedge clk);
        rst = 0;
        repeat(25) @(posedge clk);
        #1;

        test_num = test_num + 1;
        if (valid_out === 1'b0) begin
            $display("TEST %0d PASS - reset cleared pipeline, no ghost output", test_num);
            pass_count = pass_count + 1;
        end else begin
            $display("TEST %0d FAIL - valid_out high after reset!", test_num);
            fail_count = fail_count + 1;
        end

        // ════════════════════════════════════════════
        // GROUP 5: Back-to-back throughput test
        // ════════════════════════════════════════════
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

            for (watch = 0; watch < 40; watch = watch + 1) begin
                @(posedge clk);
                #1;
                if (valid_out === 1'b1) begin
                    out_count = out_count + 1;
                    $display("Block %0d out: %h", out_count, ciphertext);
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

        // ════════════════════════════════════════════
        // FINAL SUMMARY
        // ════════════════════════════════════════════
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
