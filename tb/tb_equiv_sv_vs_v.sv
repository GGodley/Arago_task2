// Lockstep equivalence check: SystemVerilog RTL vs the Verilog-2001 port.
// Both DUTs get the same stimulus every cycle; out_valid and result must match
// bit for bit on every rising edge (X compared as X via !==). Stimulus covers all
// four modes (including undefined mode 11), random valid gaps, BF16/INT corner
// values and random async resets.
// The SV copy is renamed to vec_max_alu_sv / cmp_slice_sv by scripts/check_equiv.sh.
`timescale 1ns/1ps

module tb_equiv_sv_vs_v;
    parameter integer PIPE = 1;
    parameter integer NCYC = 500000;

    reg         clk = 1'b0, rst_n = 1'b0, in_valid = 1'b0;
    reg  [1:0]  mode = 2'b00;
    reg  [63:0] in_vec = 64'd0;
    wire        ov_sv, ov_v;
    wire [15:0] r_sv, r_v;
    integer     cyc, errors = 0, nvalid = 0, j;

    vec_max_alu_sv #(.PIPE(PIPE)) u_sv (.clk(clk), .rst_n(rst_n), .in_valid(in_valid), .mode(mode),
                                        .in_vec(in_vec), .out_valid(ov_sv), .result(r_sv));
    vec_max_alu    #(.PIPE(PIPE)) u_v  (.clk(clk), .rst_n(rst_n), .in_valid(in_valid), .mode(mode),
                                        .in_vec(in_vec), .out_valid(ov_v),  .result(r_v));

    always #5 clk = ~clk;

    function automatic [15:0] corner(input integer s);
        case (s % 12)
            0: corner = 16'h0000; 1: corner = 16'h8000; 2: corner = 16'h7F80; 3: corner = 16'hFF80;
            4: corner = 16'h7FC0; 5: corner = 16'hFFC1; 6: corner = 16'h7F7F; 7: corner = 16'h8001;
            8: corner = 16'h0080; 9: corner = 16'h8080; 10: corner = 16'h7FFF; default: corner = 16'hFFFF;
        endcase
    endfunction

    always @(posedge clk) begin
        if (ov_sv !== ov_v || r_sv !== r_v) begin
            errors = errors + 1;
            if (errors <= 20)
                $display("MISMATCH @%0t: sv ov=%b r=%h   v ov=%b r=%h", $time, ov_sv, r_sv, ov_v, r_v);
        end
        if (ov_sv === 1'b1) nvalid = nvalid + 1;
    end

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        for (cyc = 0; cyc < NCYC; cyc = cyc + 1) begin
            @(negedge clk);
            if (($urandom % 5000) == 0) rst_n = 1'b0; else rst_n = 1'b1;
            in_valid = (($urandom % 4) != 0);
            mode     = $urandom;
            in_vec   = {$urandom, $urandom};
            for (j = 0; j < 4; j = j + 1)
                if (($urandom % 3) == 0) in_vec[16*j +: 16] = corner($urandom);
        end
        repeat (PIPE + 4) @(negedge clk);
        $display("PIPE=%0d: %0d cycles, %0d valid outputs compared, %0d mismatches", PIPE, NCYC, nvalid, errors);
        if (errors == 0 && nvalid > 0) $display("EQUIVALENT (PIPE=%0d)", PIPE);
        else                           $display("NOT EQUIVALENT (PIPE=%0d)", PIPE);
        $finish;
    end
endmodule
