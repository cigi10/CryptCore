// encryptRound is split into two modules:
// encryptRoundA: subBytes + shiftRows (combinational, registered externally)
// encryptRoundB: mixColumns + addRoundKey (combinational, registered externally)

module encryptRoundA(in, out);
    input  [127:0] in;
    output [127:0] out;
    wire [127:0] afterSubBytes;
    subBytes  s(in,          afterSubBytes);
    shiftRows r(afterSubBytes, out);
endmodule

module encryptRoundB(in, key, out);
    input  [127:0] in;
    input  [127:0] key;
    output [127:0] out;
    wire [127:0] afterMixColumns;
    mixColumns m(in,             afterMixColumns);
    addRoundKey b(afterMixColumns, out, key);
endmodule
