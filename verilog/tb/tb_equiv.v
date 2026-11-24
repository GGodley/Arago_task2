// Lockstep equivalence check: original SV vec_max_alu and the Verilog-2001 port
// run side by side on the same random stimulus (all four modes, including the
// undefined mode 11, random valid gaps, random mid-stream resets). out_valid and
// result must match on every clock edge, bit for bit, including X bits (!==).
// The SV copy is compiled with its modules renamed to *_sv (done by
// scripts/run_sim_verilog.sh), so both designs can live in one simulation.
`timescale 1ns/1ps

module tb_equiv;
    parameter integer PIPE   = 1;
    parameter integer NCYCLE = 2000000;

    reg         clk = 1'b0, rst_n = 1'b0, in_valid = 1'b0;
    reg  [1:0]  mode = 2'b00;
    reg  [63:0] in_vec = 64'd0;
    wire        ov_sv, ov_v;
    wire [15:0] r_sv, r_v;
    integer     cyc = 0, errors = 0, nvalid = 0;

    vec_max_alu_sv #(.PIPE(PIPE)) u_sv (.clk(clk), .rst_n(rst_n), .in_valid(in_valid), .mode(mode),
                                        .in_vec(in_vec), .out_valid(ov_sv), .result(r_sv));
    vec_max_alu    #(.PIPE(PIPE)) u_v  (.clk(clk), .rst_n(rst_n), .in_valid(in_valid), .mode(mode),
                                        .in_vec(in_vec), .out_valid(ov_v), .result(r_v));

    always #5 clk = ~clk;

    // Bias lanes towards BF16/INT corner values so ties, NaNs, +/-0 and infinities are common.
    function [15:0] pick16(input integer s);
        case ({$random} % 12)
            0: pick16 = 16'h0000; 1: pick16 = 16'h8000; 2: pick16 = 16'h7F80; 3: pick16 = 16'hFF80;
            4: pick16 = 16'h7FC0; 5: pick16 = 16'h7F81; 6: pick16 = 16'h0001; 7: pick16 = 16'h8001;
            8: pick16 = 16'h7FFF; 9: pick16 = 16'h8080; default: pick16 = $random;
        endcase
    endfunction

    always @(negedge clk) begin
        cyc = cyc + 1;
        rst_n    = ({$random} % 5000) != 0;          // occasional mid-stream reset
        in_valid = ({$random} % 8) != 0;
        mode     = $random;
        in_vec   = {pick16(0), pick16(1), pick16(2), pick16(3)};
        if (({$random} % 3) == 0) in_vec[31:0] = in_vec[63:32];   // force equal lanes / ties
    end

    always @(posedge clk) begin
        if (ov_sv) nvalid = nvalid + 1;
        if (ov_sv !== ov_v || r_sv !== r_v) begin
            errors = errors + 1;
            if (errors <= 10)
                $display("MISMATCH @%0d: SV out_valid=%b result=%h | V out_valid=%b result=%h",
                         cyc, ov_sv, r_sv, ov_v, r_v);
        end
        if (cyc == NCYCLE) begin
            $display("PIPE=%0d: %0d cycles, %0d valid outputs, %0d mismatches", PIPE, cyc, nvalid, errors);
            if (errors == 0) $display("EQUIV PASSED (PIPE=%0d)", PIPE);
            else             $display("EQUIV FAILED (PIPE=%0d)", PIPE);
            $finish;
        end
    end
endmodule
