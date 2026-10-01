`timescale 1ns/1ps

module tb;

    reg [7:0] ui_in;

    wire [7:0] uo_out;

    reg [7:0] uio_in;

    wire [7:0] uio_out;
    wire [7:0] uio_oe;

    reg ena;
    reg clk;
    reg rst_n;


    tt_um_trng_arsenal4eva dut (
        .ui_in(ui_in),
        .uo_out(uo_out),

        .uio_in(uio_in),
        .uio_out(uio_out),
        .uio_oe(uio_oe),

        .ena(ena),
        .clk(clk),
        .rst_n(rst_n)
    );


    initial begin

        clk = 1'b0;

        forever #10 clk = ~clk;

    end


    initial begin

        $dumpfile("tb.fst");
        $dumpvars(0, tb);

        ui_in = 8'b0;
        uio_in = 8'b0;

        ena = 1'b1;
        rst_n = 1'b0;

        #100;

        rst_n = 1'b1;

        #1000000;

        $finish;

    end

endmodule
