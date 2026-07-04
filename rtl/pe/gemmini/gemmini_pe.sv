// -----------------------------------------------------------------------------
// Gemmini-like Processing Element translated to synthesizable SystemVerilog.
//
// Integer, signed, synthesizable approximation of Gemmini's PE.scala.
// This version avoids parameterized SystemVerilog casts which Genus rejected.
// It is intentionally conservative for Cadence Genus parsing.
// -----------------------------------------------------------------------------

module gemmini_like_mac_unit #(
    parameter int A_W   = 8,
    parameter int B_W   = 8,
    parameter int C_W   = 32,
    parameter int OUT_W = 20
)(
    input  logic signed [A_W-1:0]   in_a,
    input  logic signed [B_W-1:0]   in_b,
    input  logic signed [C_W-1:0]   in_c,
    output logic signed [OUT_W-1:0] out_d
);

    localparam int MUL_W = A_W + B_W;
    localparam int EXT_W = (C_W > MUL_W) ? C_W : MUL_W;
    localparam int SUM_W = EXT_W + 1;

    logic signed [MUL_W-1:0] mult;
    logic signed [EXT_W-1:0] mult_ext;
    logic signed [EXT_W-1:0] c_ext;
    logic signed [SUM_W-1:0] sum_ext;

    function automatic logic signed [EXT_W-1:0] sx_mul_to_ext(
        input logic signed [MUL_W-1:0] value
    );
        integer i;
        begin
            for (i = 0; i < EXT_W; i = i + 1) begin
                if (i < MUL_W)
                    sx_mul_to_ext[i] = value[i];
                else
                    sx_mul_to_ext[i] = value[MUL_W-1];
            end
        end
    endfunction

    function automatic logic signed [EXT_W-1:0] sx_c_to_ext(
        input logic signed [C_W-1:0] value
    );
        integer i;
        begin
            for (i = 0; i < EXT_W; i = i + 1) begin
                if (i < C_W)
                    sx_c_to_ext[i] = value[i];
                else
                    sx_c_to_ext[i] = value[C_W-1];
            end
        end
    endfunction

    function automatic logic signed [SUM_W-1:0] sx_ext_to_sum(
        input logic signed [EXT_W-1:0] value
    );
        integer i;
        begin
            for (i = 0; i < SUM_W; i = i + 1) begin
                if (i < EXT_W)
                    sx_ext_to_sum[i] = value[i];
                else
                    sx_ext_to_sum[i] = value[EXT_W-1];
            end
        end
    endfunction

    function automatic logic signed [SUM_W-1:0] max_out_as_sum;
        integer i;
        begin
            for (i = 0; i < SUM_W; i = i + 1) begin
                if (i < OUT_W-1)
                    max_out_as_sum[i] = 1'b1;
                else
                    max_out_as_sum[i] = 1'b0;
            end
        end
    endfunction

    function automatic logic signed [SUM_W-1:0] min_out_as_sum;
        integer i;
        begin
            for (i = 0; i < SUM_W; i = i + 1) begin
                if (i < OUT_W-1)
                    min_out_as_sum[i] = 1'b0;
                else
                    min_out_as_sum[i] = 1'b1;
            end
        end
    endfunction

    function automatic logic signed [OUT_W-1:0] sat_to_out(
        input logic signed [SUM_W-1:0] value
    );
        logic signed [SUM_W-1:0] max_val;
        logic signed [SUM_W-1:0] min_val;
        begin
            max_val = max_out_as_sum();
            min_val = min_out_as_sum();

            if (value > max_val)
                sat_to_out = {1'b0, {(OUT_W-1){1'b1}}};
            else if (value < min_val)
                sat_to_out = {1'b1, {(OUT_W-1){1'b0}}};
            else
                sat_to_out = value[OUT_W-1:0];
        end
    endfunction

    always_comb begin
        mult     = in_a * in_b;
        mult_ext = sx_mul_to_ext(mult);
        c_ext    = sx_c_to_ext(in_c);
        sum_ext  = sx_ext_to_sum(c_ext) + sx_ext_to_sum(mult_ext);
        out_d    = sat_to_out(sum_ext);
    end

endmodule


module pe_gemmini_like #(
    parameter int INPUT_W  = 8,
    parameter int WEIGHT_W = 8,
    parameter int OUTPUT_W = 20,
    parameter int ACC_W    = 32,
    parameter int ID_W     = 1,

    // Static dataflow supported by this synthesized PE:
    //   0 = OS only
    //   1 = WS only
    //   2 = BOTH, selected at runtime by in_control_dataflow
    parameter int STATIC_DATAFLOW = 2
)(
    input  logic clk,
    input  logic rst_n,

    input  logic clear,

    input  logic signed [INPUT_W-1:0]  in_a,
    input  logic signed [OUTPUT_W-1:0] in_b,
    input  logic signed [OUTPUT_W-1:0] in_d,

    output logic signed [INPUT_W-1:0]  out_a,
    output logic signed [OUTPUT_W-1:0] out_b,
    output logic signed [OUTPUT_W-1:0] out_c,

    input  logic                       in_control_dataflow,
    input  logic                       in_control_propagate,
    input  logic [$clog2(ACC_W)-1:0]   in_control_shift,

    output logic                       out_control_dataflow,
    output logic                       out_control_propagate,
    output logic [$clog2(ACC_W)-1:0]   out_control_shift,

    input  logic [ID_W-1:0]            in_id,
    output logic [ID_W-1:0]            out_id,

    input  logic                       in_last,
    output logic                       out_last,

    input  logic                       in_valid,
    output logic                       out_valid,

    output logic                       bad_dataflow
);

    localparam logic DATAFLOW_OS = 1'b1;
    localparam logic DATAFLOW_WS = 1'b0;

    localparam int STATIC_OS   = 0;
    localparam int STATIC_WS   = 1;
    localparam int STATIC_BOTH = 2;

    localparam logic PROPAGATE = 1'b1;

    // OS uses ACC_W for local accumulation.
    // WS uses OUTPUT_W when statically specialized as WS.
    // BOTH uses ACC_W so both runtime modes have enough local precision.
    localparam int C_W = (STATIC_DATAFLOW == STATIC_WS) ? OUTPUT_W : ACC_W;

    logic signed [C_W-1:0] c1_q;
    logic signed [C_W-1:0] c2_q;
    logic                  last_s_q;

    logic                  flip;
    logic [$clog2(ACC_W)-1:0] shift_offset;

    logic use_os;
    logic use_ws;

    logic signed [WEIGHT_W-1:0] mac_in_b;
    logic signed [C_W-1:0]      mac_in_c;
    logic signed [OUTPUT_W-1:0] mac_out_d;

    function automatic logic signed [C_W-1:0] resize_output_to_c(
        input logic signed [OUTPUT_W-1:0] value
    );
        integer i;
        begin
            for (i = 0; i < C_W; i = i + 1) begin
                if (i < OUTPUT_W)
                    resize_output_to_c[i] = value[i];
                else
                    resize_output_to_c[i] = value[OUTPUT_W-1];
            end
        end
    endfunction

    function automatic logic signed [WEIGHT_W-1:0] resize_c_to_weight(
        input logic signed [C_W-1:0] value
    );
        integer i;
        begin
            for (i = 0; i < WEIGHT_W; i = i + 1) begin
                if (i < C_W)
                    resize_c_to_weight[i] = value[i];
                else
                    resize_c_to_weight[i] = value[C_W-1];
            end
        end
    endfunction

    function automatic logic signed [WEIGHT_W-1:0] resize_output_to_weight(
        input logic signed [OUTPUT_W-1:0] value
    );
        integer i;
        begin
            for (i = 0; i < WEIGHT_W; i = i + 1) begin
                if (i < OUTPUT_W)
                    resize_output_to_weight[i] = value[i];
                else
                    resize_output_to_weight[i] = value[OUTPUT_W-1];
            end
        end
    endfunction

    function automatic logic signed [OUTPUT_W-1:0] resize_c_to_output(
        input logic signed [C_W-1:0] value
    );
        integer i;
        begin
            for (i = 0; i < OUTPUT_W; i = i + 1) begin
                if (i < C_W)
                    resize_c_to_output[i] = value[i];
                else
                    resize_c_to_output[i] = value[C_W-1];
            end
        end
    endfunction

    function automatic logic signed [C_W-1:0] max_output_as_c;
        integer i;
        begin
            for (i = 0; i < C_W; i = i + 1) begin
                if (i < OUTPUT_W-1)
                    max_output_as_c[i] = 1'b1;
                else
                    max_output_as_c[i] = 1'b0;
            end
        end
    endfunction

    function automatic logic signed [C_W-1:0] min_output_as_c;
        integer i;
        begin
            for (i = 0; i < C_W; i = i + 1) begin
                if (i < OUTPUT_W-1)
                    min_output_as_c[i] = 1'b0;
                else
                    min_output_as_c[i] = 1'b1;
            end
        end
    endfunction

    function automatic logic signed [OUTPUT_W-1:0] sat_acc_to_output(
        input logic signed [C_W-1:0] value
    );
        logic signed [C_W-1:0] max_val;
        logic signed [C_W-1:0] min_val;
        begin
            if (C_W <= OUTPUT_W) begin
                sat_acc_to_output = resize_c_to_output(value);
            end else begin
                max_val = max_output_as_c();
                min_val = min_output_as_c();

                if (value > max_val)
                    sat_acc_to_output = {1'b0, {(OUTPUT_W-1){1'b1}}};
                else if (value < min_val)
                    sat_acc_to_output = {1'b1, {(OUTPUT_W-1){1'b0}}};
                else
                    sat_acc_to_output = value[OUTPUT_W-1:0];
            end
        end
    endfunction

    function automatic logic signed [OUTPUT_W-1:0] shift_and_clip_to_output(
        input logic signed [C_W-1:0] value,
        input logic [$clog2(ACC_W)-1:0] shift_amount
    );
        logic signed [C_W-1:0] shifted;
        begin
            shifted = value >>> shift_amount;
            shift_and_clip_to_output = sat_acc_to_output(shifted);
        end
    endfunction

    always_comb begin
        case (STATIC_DATAFLOW)
            STATIC_OS: begin
                use_os = 1'b1;
                use_ws = 1'b0;
            end

            STATIC_WS: begin
                use_os = 1'b0;
                use_ws = 1'b1;
            end

            default: begin
                use_os = (in_control_dataflow == DATAFLOW_OS);
                use_ws = (in_control_dataflow == DATAFLOW_WS);
            end
        endcase
    end

    assign flip         = (last_s_q != in_control_propagate);
    assign shift_offset = flip ? in_control_shift : '0;

    always_comb begin
        out_a = in_a;

        out_control_dataflow  = in_control_dataflow;
        out_control_propagate = in_control_propagate;
        out_control_shift     = in_control_shift;

        out_id    = in_id;
        out_last  = in_last;
        out_valid = in_valid;

        bad_dataflow = 1'b0;

        out_b = '0;
        out_c = '0;

        mac_in_b = resize_output_to_weight(in_b);
        mac_in_c = '0;

        if (use_os) begin
            out_b = in_b;

            if (in_control_propagate == PROPAGATE) begin
                out_c    = shift_and_clip_to_output(c1_q, shift_offset);
                mac_in_b = resize_output_to_weight(in_b);
                mac_in_c = c2_q;
            end else begin
                out_c    = shift_and_clip_to_output(c2_q, shift_offset);
                mac_in_b = resize_output_to_weight(in_b);
                mac_in_c = c1_q;
            end
        end else if (use_ws) begin
            if (in_control_propagate == PROPAGATE) begin
                out_c    = sat_acc_to_output(c1_q);
                mac_in_b = resize_c_to_weight(c2_q);
                mac_in_c = resize_output_to_c(in_b);
                out_b    = mac_out_d;
            end else begin
                out_c    = sat_acc_to_output(c2_q);
                mac_in_b = resize_c_to_weight(c1_q);
                mac_in_c = resize_output_to_c(in_b);
                out_b    = mac_out_d;
            end
        end else begin
            bad_dataflow = 1'b1;
            out_b        = '0;
            out_c        = '0;
            mac_in_b     = resize_output_to_weight(in_b);
            mac_in_c     = c2_q;
        end

        if (!in_valid) begin
            mac_in_b = '0;
            mac_in_c = '0;
        end
    end

    gemmini_like_mac_unit #(
        .A_W(INPUT_W),
        .B_W(WEIGHT_W),
        .C_W(C_W),
        .OUT_W(OUTPUT_W)
    ) u_mac_unit (
        .in_a(in_a),
        .in_b(mac_in_b),
        .in_c(mac_in_c),
        .out_d(mac_out_d)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c1_q     <= '0;
            c2_q     <= '0;
            last_s_q <= 1'b0;
        end else if (clear) begin
            c1_q     <= '0;
            c2_q     <= '0;
            last_s_q <= 1'b0;
        end else begin
            if (in_valid) begin
                last_s_q <= in_control_propagate;

                if (use_os) begin
                    if (in_control_propagate == PROPAGATE) begin
                        c2_q <= resize_output_to_c(mac_out_d);
                        c1_q <= resize_output_to_c(in_d);
                    end else begin
                        c1_q <= resize_output_to_c(mac_out_d);
                        c2_q <= resize_output_to_c(in_d);
                    end
                end else if (use_ws) begin
                    if (in_control_propagate == PROPAGATE)
                        c1_q <= resize_output_to_c(in_d);
                    else
                        c2_q <= resize_output_to_c(in_d);
                end
            end
        end
    end

endmodule
