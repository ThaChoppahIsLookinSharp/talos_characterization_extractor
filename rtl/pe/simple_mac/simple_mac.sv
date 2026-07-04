module simple_mac #(
    parameter int A_W   = 8,
    parameter int B_W   = 8,
    parameter int ACC_W = 32
)(
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic                    en,
    input  logic                    clear,

    input  logic signed [A_W-1:0]   a,
    input  logic signed [B_W-1:0]   b,

    output logic signed [ACC_W-1:0] acc
);

    logic signed [A_W+B_W-1:0] mult;
    logic signed [ACC_W-1:0]   mult_ext;

    assign mult     = a * b;
    assign mult_ext = {{(ACC_W-(A_W+B_W)){mult[A_W+B_W-1]}}, mult};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc <= '0;
        end else if (clear) begin
            acc <= '0;
        end else if (en) begin
            acc <= acc + mult_ext;
        end
    end

endmodule

