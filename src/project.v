`default_nettype none

module trng_ring_osc #(
    parameter integer DEPTH = 251
) (
    output wire osc_out
);

`ifdef VERILATOR

    assign osc_out = 1'b0;

`elsif __ICARUS__

    assign osc_out = 1'b0;

`else

    (* keep *)
    wire [DEPTH-1:0] inv_out;

    genvar i;

    generate
        for (i = 0; i < DEPTH; i = i + 1) begin : inverter_chain

            if (i == 0) begin : first_inverter

                (* keep *)
                sky130_fd_sc_hd__inv_2 inverter (
                    .A(inv_out[DEPTH-1]),
                    .Y(inv_out[0])
                );

            end
            else begin : following_inverter

                (* keep *)
                sky130_fd_sc_hd__inv_2 inverter (
                    .A(inv_out[i-1]),
                    .Y(inv_out[i])
                );

            end

        end
    endgenerate

    assign osc_out = inv_out[DEPTH-1];

`endif

endmodule


module tt_um_trng_arsenal4eva (
    input wire [7:0] ui_in,
    output wire [7:0] uo_out,

    input wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,

    input wire ena,
    input wire clk,
    input wire rst_n
);

    wire trng_enable;
    wire test_mode;

    assign trng_enable = ena & ui_in[0];
    assign test_mode = ui_in[1];


    wire entropy_async;


`ifdef VERILATOR

    reg [31:0] sim_entropy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sim_entropy <= 32'hA5C3_7F19;
        end
        else if (!trng_enable) begin
            sim_entropy <= 32'hA5C3_7F19;
        end
        else begin
            sim_entropy <= {
                sim_entropy[30:0],
                sim_entropy[31] ^
                sim_entropy[21] ^
                sim_entropy[1] ^
                sim_entropy[0]
            };
        end
    end

    assign entropy_async = sim_entropy[0];


`elsif __ICARUS__

    reg [31:0] sim_entropy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sim_entropy <= 32'hA5C3_7F19;
        end
        else if (!trng_enable) begin
            sim_entropy <= 32'hA5C3_7F19;
        end
        else begin
            sim_entropy <= {
                sim_entropy[30:0],
                sim_entropy[31] ^
                sim_entropy[21] ^
                sim_entropy[1] ^
                sim_entropy[0]
            };
        end
    end

    assign entropy_async = sim_entropy[0];


`else

    wire ro_125;
    wire ro_251;
    wire ro_503;
    wire ro_1001;

    trng_ring_osc #(
        .DEPTH(125)
    ) oscillator_125 (
        .osc_out(ro_125)
    );

    trng_ring_osc #(
        .DEPTH(251)
    ) oscillator_251 (
        .osc_out(ro_251)
    );

    trng_ring_osc #(
        .DEPTH(503)
    ) oscillator_503 (
        .osc_out(ro_503)
    );

    trng_ring_osc #(
        .DEPTH(1001)
    ) oscillator_1001 (
        .osc_out(ro_1001)
    );

    assign entropy_async =
        ro_125 ^
        ro_251 ^
        ro_503 ^
        ro_1001;

`endif


    (* async_reg = "true" *)
    reg entropy_meta;

    (* async_reg = "true" *)
    reg entropy_sync;


    reg vn_first_bit;
    reg vn_have_first;

    reg [6:0] vn_byte;
    reg [3:0] vn_count;

    reg [7:0] entropy_byte;
    reg entropy_byte_ready;

    reg [7:0] random_value;


`ifdef VERILATOR

    reg [15:0] minute_counter;

    localparam [15:0] MINUTE_COUNT = 16'd999;


`elsif __ICARUS__

    reg [15:0] minute_counter;

    localparam [15:0] MINUTE_COUNT = 16'd999;


`else

    reg [31:0] minute_counter;

    localparam [31:0] MINUTE_COUNT = 32'd2_999_999_999;

`endif


    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            entropy_meta <= 1'b0;
            entropy_sync <= 1'b0;

            vn_first_bit <= 1'b0;
            vn_have_first <= 1'b0;

            vn_byte <= 7'b0;
            vn_count <= 4'b0;

            entropy_byte <= 8'b0;
            entropy_byte_ready <= 1'b0;

            random_value <= 8'b0;

            minute_counter <= 0;

        end

        else if (!trng_enable) begin

            entropy_meta <= 1'b0;
            entropy_sync <= 1'b0;

            vn_first_bit <= 1'b0;
            vn_have_first <= 1'b0;

            vn_byte <= 7'b0;
            vn_count <= 4'b0;

            entropy_byte <= 8'b0;
            entropy_byte_ready <= 1'b0;

            minute_counter <= 0;

        end

        else begin

            entropy_meta <= entropy_async;
            entropy_sync <= entropy_meta;


            if (!vn_have_first) begin

                vn_first_bit <= entropy_sync;
                vn_have_first <= 1'b1;

            end

            else begin

                vn_have_first <= 1'b0;


                if ((vn_first_bit == 1'b0) &&
                    (entropy_sync == 1'b1)) begin

                    if (vn_count == 4'd7) begin

                        entropy_byte <= {
                            vn_byte,
                            1'b0
                        };

                        entropy_byte_ready <= 1'b1;

                        vn_byte <= 7'b0;
                        vn_count <= 4'd0;

                    end
                    else begin

                        vn_byte <= {
                            vn_byte[5:0],
                            1'b0
                        };

                        vn_count <= vn_count + 1'b1;

                    end

                end


                else if ((vn_first_bit == 1'b1) &&
                         (entropy_sync == 1'b0)) begin

                    if (vn_count == 4'd7) begin

                        entropy_byte <= {
                            vn_byte,
                            1'b1
                        };

                        entropy_byte_ready <= 1'b1;

                        vn_byte <= 7'b0;
                        vn_count <= 4'd0;

                    end
                    else begin

                        vn_byte <= {
                            vn_byte[5:0],
                            1'b1
                        };

                        vn_count <= vn_count + 1'b1;

                    end

                end

            end


            if (minute_counter == MINUTE_COUNT) begin

                minute_counter <= 0;

                if (entropy_byte_ready) begin

                    random_value <= entropy_byte;
                    entropy_byte_ready <= 1'b0;

                end

            end
            else begin

                minute_counter <= minute_counter + 1'b1;

            end

        end

    end


    assign uo_out =
        test_mode
        ? entropy_byte
        : random_value;


    assign uio_out = 8'b0;
    assign uio_oe = 8'b0;


    wire _unused;

    assign _unused = &{
        ui_in[7:2],
        uio_in
    };

endmodule

`default_nettype wire
