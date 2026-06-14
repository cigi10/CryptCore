`timescale 1ns / 1ps


module aes256_axi_wrapper #(
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 8
)(
    input  wire        S_AXI_ACLK,
    input  wire        S_AXI_ARESETN,   

    // Write address channel
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] S_AXI_AWADDR,
    input  wire        S_AXI_AWVALID,
    output reg         S_AXI_AWREADY,

    // Write data channel
    input  wire [C_S_AXI_DATA_WIDTH-1:0] S_AXI_WDATA,
    input  wire [3:0]  S_AXI_WSTRB,
    input  wire        S_AXI_WVALID,
    output reg         S_AXI_WREADY,

    // Write response channel
    output reg  [1:0]  S_AXI_BRESP,
    output reg         S_AXI_BVALID,
    input  wire        S_AXI_BREADY,

    // Read address channel
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] S_AXI_ARADDR,
    input  wire        S_AXI_ARVALID,
    output reg         S_AXI_ARREADY,

    // Read data channel
    output reg  [C_S_AXI_DATA_WIDTH-1:0] S_AXI_RDATA,
    output reg  [1:0]  S_AXI_RRESP,
    output reg         S_AXI_RVALID,
    input  wire        S_AXI_RREADY
);

    wire clk = S_AXI_ACLK;
    wire rst = ~S_AXI_ARESETN;   

    reg         ctrl_start;
    reg [31:0]  key_reg [0:7];  
    reg [31:0]  pt_reg  [0:3];  

    reg [31:0]  ct_reg  [0:3];   
    reg         status_done;

    wire [255:0] core_key        = { key_reg[0], key_reg[1], key_reg[2], key_reg[3],
                                     key_reg[4], key_reg[5], key_reg[6], key_reg[7] };
    wire [127:0] core_plaintext  = { pt_reg[0],  pt_reg[1],  pt_reg[2],  pt_reg[3]  };
    wire [127:0] core_ciphertext;
    wire         core_valid_out;

    reg          core_key_valid;
    reg          core_valid_in;

    aes256_pipelined aes_core (
        .clk        (clk),
        .rst        (rst),
        .key        (core_key),
        .key_valid  (core_key_valid),
        .plaintext  (core_plaintext),
        .valid_in   (core_valid_in),
        .ciphertext (core_ciphertext),
        .valid_out  (core_valid_out)
    );

    always @(posedge clk) begin
        if (rst) begin
            ct_reg[0]   <= 32'b0;
            ct_reg[1]   <= 32'b0;
            ct_reg[2]   <= 32'b0;
            ct_reg[3]   <= 32'b0;
            status_done <= 1'b0;
        end else if (core_valid_in) begin
            status_done <= 1'b0;
        end else if (core_valid_out) begin
            ct_reg[0]   <= core_ciphertext[127:96];
            ct_reg[1]   <= core_ciphertext[95:64];
            ct_reg[2]   <= core_ciphertext[63:32];
            ct_reg[3]   <= core_ciphertext[31:0];
            status_done <= 1'b1;
        end
    end

    reg [C_S_AXI_ADDR_WIDTH-1:0] write_addr;
    reg write_addr_valid;
    reg write_data_valid;
    reg [31:0] write_data;

    always @(posedge clk) begin
        if (rst) begin
            S_AXI_AWREADY    <= 1'b0;
            S_AXI_WREADY     <= 1'b0;
            S_AXI_BVALID     <= 1'b0;
            S_AXI_BRESP      <= 2'b00;
            write_addr_valid <= 1'b0;
            write_data_valid <= 1'b0;
            ctrl_start       <= 1'b0;
            core_key_valid   <= 1'b0;
            core_valid_in    <= 1'b0;
            key_reg[0] <= 32'b0; key_reg[1] <= 32'b0;
            key_reg[2] <= 32'b0; key_reg[3] <= 32'b0;
            key_reg[4] <= 32'b0; key_reg[5] <= 32'b0;
            key_reg[6] <= 32'b0; key_reg[7] <= 32'b0;
            pt_reg[0]  <= 32'b0; pt_reg[1]  <= 32'b0;
            pt_reg[2]  <= 32'b0; pt_reg[3]  <= 32'b0;
        end else begin
            core_key_valid <= 1'b0;
            core_valid_in  <= 1'b0;
            ctrl_start     <= 1'b0;

            if (S_AXI_AWVALID && !S_AXI_AWREADY) begin
                S_AXI_AWREADY    <= 1'b1;
                write_addr       <= S_AXI_AWADDR;
                write_addr_valid <= 1'b1;
            end else begin
                S_AXI_AWREADY <= 1'b0;
            end

            if (S_AXI_WVALID && !S_AXI_WREADY) begin
                S_AXI_WREADY     <= 1'b1;
                write_data       <= S_AXI_WDATA;
                write_data_valid <= 1'b1;
            end else begin
                S_AXI_WREADY <= 1'b0;
            end

            if (write_addr_valid && write_data_valid) begin
                write_addr_valid <= 1'b0;
                write_data_valid <= 1'b0;
                S_AXI_BVALID     <= 1'b1;
                S_AXI_BRESP      <= 2'b00; 

                case (write_addr[7:0])
                    8'h00: begin
                        ctrl_start <= write_data[0];
                        if (write_data[1]) core_key_valid <= 1'b1;  
                        if (write_data[0]) core_valid_in  <= 1'b1;  
                    end
                    8'h08: key_reg[0] <= write_data;
                    8'h0C: key_reg[1] <= write_data;
                    8'h10: key_reg[2] <= write_data;
                    8'h14: key_reg[3] <= write_data;
                    8'h18: key_reg[4] <= write_data;
                    8'h1C: key_reg[5] <= write_data;
                    8'h20: key_reg[6] <= write_data;
                    8'h24: key_reg[7] <= write_data;
                    8'h28: pt_reg[0]  <= write_data;
                    8'h2C: pt_reg[1]  <= write_data;
                    8'h30: pt_reg[2]  <= write_data;
                    8'h34: pt_reg[3]  <= write_data;
                    default: ;  
                endcase
            end

            
            if (S_AXI_BVALID && S_AXI_BREADY)
                S_AXI_BVALID <= 1'b0;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            S_AXI_ARREADY <= 1'b0;
            S_AXI_RVALID  <= 1'b0;
            S_AXI_RDATA   <= 32'b0;
            S_AXI_RRESP   <= 2'b00;
        end else begin
            if (S_AXI_ARVALID && !S_AXI_ARREADY) begin
                S_AXI_ARREADY <= 1'b1;
                S_AXI_RVALID  <= 1'b1;
                S_AXI_RRESP   <= 2'b00;  

                case (S_AXI_ARADDR[7:0])
                    8'h04: S_AXI_RDATA <= {31'b0, status_done};
                    8'h38: S_AXI_RDATA <= ct_reg[0];
                    8'h3C: S_AXI_RDATA <= ct_reg[1];
                    8'h40: S_AXI_RDATA <= ct_reg[2];
                    8'h44: S_AXI_RDATA <= ct_reg[3];
                    default: S_AXI_RDATA <= 32'hDEADBEEF;  
                endcase
            end else begin
                S_AXI_ARREADY <= 1'b0;
            end

            if (S_AXI_RVALID && S_AXI_RREADY)
                S_AXI_RVALID <= 1'b0;
        end
    end

endmodule
