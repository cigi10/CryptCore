`timescale 1ns / 1ps

module aes256_pipelined (
    input  wire         clk,
    input  wire         rst,
    input  wire [255:0] key,
    input  wire         key_valid,
    input  wire [127:0] plaintext,
    input  wire         valid_in,
    output reg  [127:0] ciphertext,
    output reg          valid_out
);

    wire [1919:0] round_keys_raw;
    wire          key_ready;

    keyExpansion #(.nk(8), .nr(14)) ke (
        .clk       (clk),
        .rst       (rst),
        .key       (key),
        .key_valid (key_valid),
        .w         (round_keys_raw),
        .ready     (key_ready)
    );


    reg [1919:0] round_keys_reg;
    always @(posedge clk) begin
        if (rst)
            round_keys_reg <= 0;
        else if (key_ready)
            round_keys_reg <= round_keys_raw;
    end

    reg [127:0] stage [0:26];
    reg         vld   [0:28];   

    wire [127:0] ark0_out;
    wire [127:0] roundA_out [1:13];
    wire [127:0] roundB_out [1:13];

    wire [127:0] final_sb_wire;
    wire [127:0] final_sr_wire;
    wire [127:0] final_ark_wire;

    reg  [127:0] final_sb_reg;
    reg  [127:0] final_sr_reg;

    addRoundKey ark0 (
        .data (plaintext),
        .key  (round_keys_reg[1919:1792]),  
        .out  (ark0_out)
    );

    always @(posedge clk) begin
        if (rst) begin
            stage[0] <= 128'b0;
            vld[0]   <= 1'b0;
        end else begin
            stage[0] <= ark0_out;
            vld[0]   <= valid_in & key_ready;
        end
    end


    genvar i;
    generate
        for (i = 1; i <= 13; i = i + 1) begin : pipe

            encryptRoundA rA (
                .in  (stage[(i-1)*2]),
                .out (roundA_out[i])
            );

            always @(posedge clk) begin
                if (rst) begin
                    stage[i*2-1] <= 128'b0;
                    vld[i*2-1]   <= 1'b0;
                end else begin
                    stage[i*2-1] <= roundA_out[i];
                    vld[i*2-1]   <= vld[(i-1)*2];
                end
            end

            encryptRoundB rB (
                .in  (stage[i*2-1]),
                .key (round_keys_reg[(1919 - 128*i) -: 128]),
                .out (roundB_out[i])
            );

            always @(posedge clk) begin
                if (rst) begin
                    stage[i*2] <= 128'b0;
                    vld[i*2]   <= 1'b0;
                end else begin
                    stage[i*2] <= roundB_out[i];
                    vld[i*2]   <= vld[i*2-1];
                end
            end

        end
    endgenerate


    subBytes sb_final (
        .in  (stage[26]),
        .out (final_sb_wire)
    );

    always @(posedge clk) begin
        if (rst) begin
            final_sb_reg <= 128'b0;
            vld[27]      <= 1'b0;
        end else begin
            final_sb_reg <= final_sb_wire;
            vld[27]      <= vld[26];
        end
    end

    shiftRows sr_final (
        .in      (final_sb_reg),
        .shifted (final_sr_wire)
    );

    always @(posedge clk) begin
        if (rst) begin
            final_sr_reg <= 128'b0;
            vld[28]      <= 1'b0;
        end else begin
            final_sr_reg <= final_sr_wire;
            vld[28]      <= vld[27];
        end
    end

    addRoundKey ark_final (
        .data (final_sr_reg),
        .key  (round_keys_reg[127:0]),   
        .out  (final_ark_wire)
    );

    always @(posedge clk) begin
        if (rst) begin
            ciphertext <= 128'b0;
            valid_out  <= 1'b0;
        end else begin
            ciphertext <= final_ark_wire;
            valid_out  <= vld[28];
        end
    end

endmodule
