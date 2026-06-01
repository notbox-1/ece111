module bitcoin_hash (input logic        clk, reset_n, start,
                     input logic [15:0] message_addr, output_addr,
                    output logic        done, mem_clk, mem_we,
                    output logic [15:0] mem_addr,
                    output logic [31:0] mem_write_data,
                     input logic [31:0] mem_read_data);

parameter num_nonces = 16;
parameter BATCH_SIZE = 8;

parameter int k[64] = '{
    32'h428a2f98,32'h71374491,32'hb5c0fbcf,32'he9b5dba5,32'h3956c25b,32'h59f111f1,32'h923f82a4,32'hab1c5ed5,
    32'hd807aa98,32'h12835b01,32'h243185be,32'h550c7dc3,32'h72be5d74,32'h80deb1fe,32'h9bdc06a7,32'hc19bf174,
    32'he49b69c1,32'hefbe4786,32'h0fc19dc6,32'h240ca1cc,32'h2de92c6f,32'h4a7484aa,32'h5cb0a9dc,32'h76f988da,
    32'h983e5152,32'ha831c66d,32'hb00327c8,32'hbf597fc7,32'hc6e00bf3,32'hd5a79147,32'h06ca6351,32'h14292967,
    32'h27b70a85,32'h2e1b2138,32'h4d2c6dfc,32'h53380d13,32'h650a7354,32'h766a0abb,32'h81c2c92e,32'h92722c85,
    32'ha2bfe8a1,32'ha81a664b,32'hc24b8b70,32'hc76c51a3,32'hd192e819,32'hd6990624,32'hf40e3585,32'h106aa070,
    32'h19a4c116,32'h1e376c08,32'h2748774c,32'h34b0bcb5,32'h391c0cb3,32'h4ed8aa4a,32'h5b9cca4f,32'h682e6ff3,
    32'h748f82ee,32'h78a5636f,32'h84c87814,32'h8cc70208,32'h90befffa,32'ha4506ceb,32'hbef9a3f7,32'hc67178f2
};

// ─────────────────────────────────────────────────────────────────────────────
// State machine
// ─────────────────────────────────────────────────────────────────────────────
typedef enum logic [4:0] {
    IDLE,
    READ_SETUP,
    READ_WAIT,
    READ_CAPTURE,

    PHASE1_INIT,
    PHASE1_COMPUTE,

    PHASE2A_INIT,
    PHASE2A_COMPUTE,

    PHASE3A_INIT,
    PHASE3A_COMPUTE,

    PHASE2B_INIT,
    PHASE2B_COMPUTE,

    PHASE3B_INIT,
    PHASE3B_COMPUTE,

    WRITE_SETUP,
    WRITE_ENABLE,
    WRITE_NEXT,

    DONE_STATE
} state_t;

state_t state;

// ─────────────────────────────────────────────────────────────────────────────
// Memory / message storage
// ─────────────────────────────────────────────────────────────────────────────
logic [31:0] message [0:18];
logic [31:0] hout    [0:num_nonces-1];

// ─────────────────────────────────────────────────────────────────────────────
// Phase-1 scalar registers
// ─────────────────────────────────────────────────────────────────────────────
logic [31:0] w1 [0:15];
logic [31:0] a1, b1, c1, d1, e1, f1, g1, h1_reg;
logic [31:0] h0_r, h1_r, h2_r, h3_r, h4_r, h5_r, h6_r, h7_r;

// Pipeline registers for Phase-1:
//   wk1_pre  = w1_round + k[round+1]  (registered one cycle ahead)
//   h1_pre   = g1                      (registered one cycle ahead, becomes next h)
logic [31:0] wk1_pre;   // pipelined w+k for scalar phase
logic [31:0] h1_pre;    // pipelined h for scalar phase

// Saved Phase-1 output
logic [31:0] phase1_h0, phase1_h1, phase1_h2, phase1_h3;
logic [31:0] phase1_h4, phase1_h5, phase1_h6, phase1_h7;

// ─────────────────────────────────────────────────────────────────────────────
// Phase-2 / Phase-3 parallel arrays (8 instances, lockstep)
// ─────────────────────────────────────────────────────────────────────────────
logic [31:0] wp  [0:BATCH_SIZE-1][0:15];
logic [31:0] ap  [0:BATCH_SIZE-1];
logic [31:0] bp  [0:BATCH_SIZE-1];
logic [31:0] cp  [0:BATCH_SIZE-1];
logic [31:0] dp  [0:BATCH_SIZE-1];
logic [31:0] ep  [0:BATCH_SIZE-1];
logic [31:0] fp  [0:BATCH_SIZE-1];
logic [31:0] gp  [0:BATCH_SIZE-1];
logic [31:0] hp  [0:BATCH_SIZE-1];

logic [31:0] h0p [0:BATCH_SIZE-1];
logic [31:0] h1p [0:BATCH_SIZE-1];
logic [31:0] h2p [0:BATCH_SIZE-1];
logic [31:0] h3p [0:BATCH_SIZE-1];
logic [31:0] h4p [0:BATCH_SIZE-1];
logic [31:0] h5p [0:BATCH_SIZE-1];
logic [31:0] h6p [0:BATCH_SIZE-1];
logic [31:0] h7p [0:BATCH_SIZE-1];

// Pipeline registers for parallel phases:
//   wkp_pre[i] = w_round_p[i] + k[round+1]  (registered one cycle ahead)
//   hp_pre[i]  = gp[i]                        (registered one cycle ahead)
logic [31:0] wkp_pre [0:BATCH_SIZE-1];
logic [31:0] hp_pre  [0:BATCH_SIZE-1];

// Phase-2 output buffer (reused per batch)
logic [31:0] phase2_h [0:BATCH_SIZE-1][0:7];

// ─────────────────────────────────────────────────────────────────────────────
// Combinational signals
// ─────────────────────────────────────────────────────────────────────────────

// Phase-1 scalar
logic [31:0]  w1_new;
logic [31:0]  w1_round;
logic [255:0] round_result1;

// Parallel (8 instances)
logic [31:0]  w_new_p    [0:BATCH_SIZE-1];
logic [31:0]  w_round_p  [0:BATCH_SIZE-1];
logic [255:0] round_result_p [0:BATCH_SIZE-1];

// ─────────────────────────────────────────────────────────────────────────────
// Counters / memory control
// ─────────────────────────────────────────────────────────────────────────────
logic [7:0]  round;
logic [4:0]  read_count;
logic [4:0]  write_count;

logic [15:0] cur_mem_addr;
logic        cur_mem_we;
logic [31:0] cur_mem_write_data;

assign mem_clk        = clk;
assign mem_addr       = cur_mem_addr;
assign mem_we         = cur_mem_we;
assign mem_write_data = cur_mem_write_data;
assign done           = (state == DONE_STATE);

// ─────────────────────────────────────────────────────────────────────────────
// Helper functions
// ─────────────────────────────────────────────────────────────────────────────
function logic [31:0] rightrotate(input logic [31:0] x, input logic [7:0] r);
begin
    rightrotate = (x >> r) | (x << (32 - r));
end
endfunction

function logic [31:0] word_expand(input logic [31:0] wm16, wm15, wm7, wm2);
    logic [31:0] s0, s1;
begin
    s0 = rightrotate(wm15, 7) ^ rightrotate(wm15, 18) ^ (wm15 >> 3);
    s1 = rightrotate(wm2, 17) ^ rightrotate(wm2, 19)  ^ (wm2  >> 10);
    word_expand = wm16 + s0 + wm7 + s1;
end
endfunction

// ── Pipelined sha256_op ───────────────────────────────────────────────────────
// Accepts pre-registered (w+k) and pre-registered h instead of raw w, t, h.
// Critical path is now: S1+ch path and S0+maj path, both feeding a single
// adder — the w+k+h term is already a stable registered value at cycle start.
//
//   t1 = wk_pre + h_pre + S1 + ch        (wk_pre = w+k from prev cycle)
//   t2 = S0 + maj                         (unchanged)
//   next_a = t1 + t2
//   next_e = d + t1
//
function logic [255:0] sha256_op_pipe(
    input logic [31:0] a, b, c, d, e, f, g,
    input logic [31:0] wk_pre,   // pre-registered: w[round] + k[round]
    input logic [31:0] h_pre);   // pre-registered: h (= prev-cycle g)
    logic [31:0] S1, S0, ch, maj, t1, t2;
begin
    S1  = rightrotate(e, 6) ^ rightrotate(e, 11) ^ rightrotate(e, 25);
    ch  = (e & f) ^ ((~e) & g);
    t1  = wk_pre + h_pre + S1 + ch;   // w+k already absorbed; h already stable
    S0  = rightrotate(a, 2) ^ rightrotate(a, 13) ^ rightrotate(a, 22);
    maj = (a & b) ^ (a & c) ^ (b & c);
    t2  = S0 + maj;
    sha256_op_pipe = {t1 + t2, a, b, c, d + t1, e, f, g};
end
endfunction

// ─────────────────────────────────────────────────────────────────────────────
// Phase-1 combinational
// ─────────────────────────────────────────────────────────────────────────────
assign w1_new   = word_expand(w1[0], w1[1], w1[9], w1[14]);
assign w1_round = (round < 8'd16) ? w1[round[3:0]] : w1_new;

// round_result1 uses the pre-registered wk1_pre and h1_pre
assign round_result1 = sha256_op_pipe(a1, b1, c1, d1, e1, f1, g1, wk1_pre, h1_pre);

// ─────────────────────────────────────────────────────────────────────────────
// Parallel phase combinational (8 instances, lockstep)
// ─────────────────────────────────────────────────────────────────────────────
genvar gi;
generate
    for (gi = 0; gi < BATCH_SIZE; gi++) begin : parallel_sha
        assign w_new_p[gi]   = word_expand(wp[gi][0], wp[gi][1], wp[gi][9], wp[gi][14]);
        assign w_round_p[gi] = (round < 8'd16) ? wp[gi][round[3:0]] : w_new_p[gi];
        assign round_result_p[gi] = sha256_op_pipe(
            ap[gi], bp[gi], cp[gi], dp[gi], ep[gi], fp[gi], gp[gi],
            wkp_pre[gi], hp_pre[gi]);
    end
endgenerate

// ─────────────────────────────────────────────────────────────────────────────
// FSM
// ─────────────────────────────────────────────────────────────────────────────
always_ff @(posedge clk or negedge reset_n) begin

    if (!reset_n) begin
        state              <= IDLE;
        cur_mem_addr       <= 16'd0;
        cur_mem_we         <= 1'b0;
        cur_mem_write_data <= 32'd0;
        read_count         <= 5'd0;
        write_count        <= 5'd0;
        round              <= 8'd0;

        h0_r <= 32'd0; h1_r <= 32'd0; h2_r <= 32'd0; h3_r <= 32'd0;
        h4_r <= 32'd0; h5_r <= 32'd0; h6_r <= 32'd0; h7_r <= 32'd0;
        a1 <= 32'd0; b1 <= 32'd0; c1 <= 32'd0; d1 <= 32'd0;
        e1 <= 32'd0; f1 <= 32'd0; g1 <= 32'd0; h1_reg <= 32'd0;
        wk1_pre <= 32'd0; h1_pre <= 32'd0;

        phase1_h0 <= 32'd0; phase1_h1 <= 32'd0;
        phase1_h2 <= 32'd0; phase1_h3 <= 32'd0;
        phase1_h4 <= 32'd0; phase1_h5 <= 32'd0;
        phase1_h6 <= 32'd0; phase1_h7 <= 32'd0;

        for (int i = 0; i < BATCH_SIZE; i++) begin
            ap[i] <= 32'd0; bp[i] <= 32'd0;
            cp[i] <= 32'd0; dp[i] <= 32'd0;
            ep[i] <= 32'd0; fp[i] <= 32'd0;
            gp[i] <= 32'd0; hp[i] <= 32'd0;
            h0p[i] <= 32'd0; h1p[i] <= 32'd0;
            h2p[i] <= 32'd0; h3p[i] <= 32'd0;
            h4p[i] <= 32'd0; h5p[i] <= 32'd0;
            h6p[i] <= 32'd0; h7p[i] <= 32'd0;
            wkp_pre[i] <= 32'd0; hp_pre[i] <= 32'd0;
            for (int j = 0; j < 16; j++)
                wp[i][j] <= 32'd0;
        end
    end

    else begin
        case (state)

            // ── IDLE ──────────────────────────────────────────────────────────
            IDLE: begin
                cur_mem_we         <= 1'b0;
                cur_mem_write_data <= 32'd0;
                read_count         <= 5'd0;
                write_count        <= 5'd0;
                round              <= 8'd0;
                if (start) state   <= READ_SETUP;
            end

            // ── MEMORY READ ────────────────────────────────────────────────────
            READ_SETUP: begin
                cur_mem_we   <= 1'b0;
                cur_mem_addr <= message_addr + read_count;
                state        <= READ_WAIT;
            end
            READ_WAIT:    state <= READ_CAPTURE;
            READ_CAPTURE: begin
                message[read_count] <= mem_read_data;
                if (read_count == 5'd18) begin
                    read_count <= 5'd0;
                    state      <= PHASE1_INIT;
                end else begin
                    read_count <= read_count + 5'd1;
                    state      <= READ_SETUP;
                end
            end

            // ── PHASE 1 INIT ───────────────────────────────────────────────────
            // Loads w1, a..h, hash accumulators.
            // Also primes wk1_pre = w1[0] + k[0] and h1_pre = h (= SHA256 init H7)
            // so that COMPUTE round 0 sees valid pipeline registers immediately.
            PHASE1_INIT: begin
                for (int n = 0; n < 16; n++)
                    w1[n] <= message[n];

                h0_r <= 32'h6a09e667; h1_r <= 32'hbb67ae85;
                h2_r <= 32'h3c6ef372; h3_r <= 32'ha54ff53a;
                h4_r <= 32'h510e527f; h5_r <= 32'h9b05688c;
                h6_r <= 32'h1f83d9ab; h7_r <= 32'h5be0cd19;

                a1     <= 32'h6a09e667; b1  <= 32'hbb67ae85;
                c1     <= 32'h3c6ef372; d1  <= 32'ha54ff53a;
                e1     <= 32'h510e527f; f1  <= 32'h9b05688c;
                g1     <= 32'h1f83d9ab; h1_reg <= 32'h5be0cd19;

                // Prime pipeline: w[0]+k[0], and h = initial H7 = 0x5be0cd19
                wk1_pre <= message[0] + 32'h428a2f98;   // w1[0] + k[0]
                h1_pre  <= 32'h5be0cd19;                 // initial H7 (= initial h)

                round <= 8'd0;
                state <= PHASE1_COMPUTE;
            end

            // ── PHASE 1 COMPUTE ─────────────────────────────────────────────────
            // Each cycle:
            //   1. Apply pipelined sha256_op using wk1_pre and h1_pre
            //   2. Shift w schedule if round >= 16
            //   3. Register next cycle's wk1_pre = w_next + k[round+1]
            //      and h1_pre = current g1 (which becomes next h)
            PHASE1_COMPUTE: begin
                {a1, b1, c1, d1, e1, f1, g1, h1_reg} <= round_result1;

                if (round >= 8'd16) begin
                    for (int n = 0; n < 15; n++)
                        w1[n] <= w1[n+1];
                    w1[15] <= w1_new;
                end

                if (round == 8'd63) begin
                    // Finalise Phase-1 hash
                    phase1_h0 <= h0_r + round_result1[255:224];
                    phase1_h1 <= h1_r + round_result1[223:192];
                    phase1_h2 <= h2_r + round_result1[191:160];
                    phase1_h3 <= h3_r + round_result1[159:128];
                    phase1_h4 <= h4_r + round_result1[127:96];
                    phase1_h5 <= h5_r + round_result1[95:64];
                    phase1_h6 <= h6_r + round_result1[63:32];
                    phase1_h7 <= h7_r + round_result1[31:0];
                    state     <= PHASE2A_INIT;
                end else begin
                    round <= round + 8'd1;
                    // Pre-register w+k for round+1:
                    // After schedule shift, next w[0] is current w1[1] (rounds <16)
                    // or w1_new (rounds >=16). Use w1_round with round+1 to select.
                    // Since this fires before the shift registers update (non-blocking),
                    // we compute w_next directly from the current w1 window.
                    if (round < 8'd15)
                        wk1_pre <= w1[round[3:0] + 4'd1] + k[round + 1];
                    else if (round == 8'd15)
                        // round+1 = 16: first expanded word = word_expand(w1[0..])
                        // but shift hasn't happened yet so w1[1] is Wt-15 for t=16
                        wk1_pre <= word_expand(w1[0], w1[1], w1[9], w1[14]) + k[16];
                    else
                        // rounds 16-62: next w is word_expand of the *shifted* window,
                        // i.e. word_expand(w1[1], w1[2], w1[10], w1[15]) pre-shift
                        wk1_pre <= word_expand(w1[1], w1[2], w1[10], w1[15]) + k[round + 1];
                    // Pre-register h: next h = current g
                    h1_pre <= g1;
                end
            end

            // ── PHASE 2A INIT (nonces 0–7) ─────────────────────────────────────
            PHASE2A_INIT: begin
                for (int i = 0; i < BATCH_SIZE; i++) begin
                    wp[i][0]  <= message[16];
                    wp[i][1]  <= message[17];
                    wp[i][2]  <= message[18];
                    wp[i][3]  <= {27'd0, i[4:0]};       // nonce 0..7
                    wp[i][4]  <= 32'h80000000;
                    wp[i][5]  <= 32'd0; wp[i][6]  <= 32'd0;
                    wp[i][7]  <= 32'd0; wp[i][8]  <= 32'd0;
                    wp[i][9]  <= 32'd0; wp[i][10] <= 32'd0;
                    wp[i][11] <= 32'd0; wp[i][12] <= 32'd0;
                    wp[i][13] <= 32'd0; wp[i][14] <= 32'd0;
                    wp[i][15] <= 32'd640;

                    h0p[i] <= phase1_h0; h1p[i] <= phase1_h1;
                    h2p[i] <= phase1_h2; h3p[i] <= phase1_h3;
                    h4p[i] <= phase1_h4; h5p[i] <= phase1_h5;
                    h6p[i] <= phase1_h6; h7p[i] <= phase1_h7;

                    ap[i] <= phase1_h0; bp[i] <= phase1_h1;
                    cp[i] <= phase1_h2; dp[i] <= phase1_h3;
                    ep[i] <= phase1_h4; fp[i] <= phase1_h5;
                    gp[i] <= phase1_h6; hp[i] <= phase1_h7;

                    // Prime pipeline: w[0]+k[0], h = phase1_H7
                    wkp_pre[i] <= message[16] + 32'h428a2f98;  // wp[i][0] + k[0]
                    hp_pre[i]  <= phase1_h7;                    // initial h for this batch
                end
                round <= 8'd0;
                state <= PHASE2A_COMPUTE;
            end

            // ── PHASE 2A COMPUTE ────────────────────────────────────────────────
            PHASE2A_COMPUTE: begin
                for (int i = 0; i < BATCH_SIZE; i++) begin
                    {ap[i], bp[i], cp[i], dp[i],
                     ep[i], fp[i], gp[i], hp[i]} <= round_result_p[i];

                    if (round >= 8'd16) begin
                        for (int n = 0; n < 15; n++)
                            wp[i][n] <= wp[i][n+1];
                        wp[i][15] <= w_new_p[i];
                    end
                end

                if (round == 8'd63) begin
                    for (int i = 0; i < BATCH_SIZE; i++) begin
                        phase2_h[i][0] <= h0p[i] + round_result_p[i][255:224];
                        phase2_h[i][1] <= h1p[i] + round_result_p[i][223:192];
                        phase2_h[i][2] <= h2p[i] + round_result_p[i][191:160];
                        phase2_h[i][3] <= h3p[i] + round_result_p[i][159:128];
                        phase2_h[i][4] <= h4p[i] + round_result_p[i][127:96];
                        phase2_h[i][5] <= h5p[i] + round_result_p[i][95:64];
                        phase2_h[i][6] <= h6p[i] + round_result_p[i][63:32];
                        phase2_h[i][7] <= h7p[i] + round_result_p[i][31:0];
                    end
                    state <= PHASE3A_INIT;
                end else begin
                    round <= round + 8'd1;
                    // Pre-register w+k and h for next round (all 8 instances lockstep)
                    for (int i = 0; i < BATCH_SIZE; i++) begin
                        if (round < 8'd15)
                            wkp_pre[i] <= wp[i][round[3:0] + 4'd1] + k[round + 1];
                        else if (round == 8'd15)
                            wkp_pre[i] <= word_expand(wp[i][0], wp[i][1],
                                                      wp[i][9], wp[i][14]) + k[16];
                        else
                            wkp_pre[i] <= word_expand(wp[i][1], wp[i][2],
                                                      wp[i][10], wp[i][15]) + k[round + 1];
                        hp_pre[i] <= gp[i];   // next h = current g
                    end
                end
            end

            // ── PHASE 3A INIT (nonces 0–7 second hash) ─────────────────────────
            PHASE3A_INIT: begin
                for (int i = 0; i < BATCH_SIZE; i++) begin
                    wp[i][0]  <= phase2_h[i][0];
                    wp[i][1]  <= phase2_h[i][1];
                    wp[i][2]  <= phase2_h[i][2];
                    wp[i][3]  <= phase2_h[i][3];
                    wp[i][4]  <= phase2_h[i][4];
                    wp[i][5]  <= phase2_h[i][5];
                    wp[i][6]  <= phase2_h[i][6];
                    wp[i][7]  <= phase2_h[i][7];
                    wp[i][8]  <= 32'h80000000;
                    wp[i][9]  <= 32'd0; wp[i][10] <= 32'd0;
                    wp[i][11] <= 32'd0; wp[i][12] <= 32'd0;
                    wp[i][13] <= 32'd0; wp[i][14] <= 32'd0;
                    wp[i][15] <= 32'd256;

                    h0p[i] <= 32'h6a09e667; h1p[i] <= 32'hbb67ae85;
                    h2p[i] <= 32'h3c6ef372; h3p[i] <= 32'ha54ff53a;
                    h4p[i] <= 32'h510e527f; h5p[i] <= 32'h9b05688c;
                    h6p[i] <= 32'h1f83d9ab; h7p[i] <= 32'h5be0cd19;

                    ap[i] <= 32'h6a09e667; bp[i] <= 32'hbb67ae85;
                    cp[i] <= 32'h3c6ef372; dp[i] <= 32'ha54ff53a;
                    ep[i] <= 32'h510e527f; fp[i] <= 32'h9b05688c;
                    gp[i] <= 32'h1f83d9ab; hp[i] <= 32'h5be0cd19;

                    // Prime: wp[i][0] + k[0], h = SHA256 init H7
                    wkp_pre[i] <= phase2_h[i][0] + 32'h428a2f98;
                    hp_pre[i]  <= 32'h5be0cd19;
                end
                round <= 8'd0;
                state <= PHASE3A_COMPUTE;
            end

            // ── PHASE 3A COMPUTE ─────────────────────────────────────────────────
            PHASE3A_COMPUTE: begin
                for (int i = 0; i < BATCH_SIZE; i++) begin
                    {ap[i], bp[i], cp[i], dp[i],
                     ep[i], fp[i], gp[i], hp[i]} <= round_result_p[i];

                    if (round >= 8'd16) begin
                        for (int n = 0; n < 15; n++)
                            wp[i][n] <= wp[i][n+1];
                        wp[i][15] <= w_new_p[i];
                    end
                end

                if (round == 8'd63) begin
                    for (int i = 0; i < BATCH_SIZE; i++)
                        hout[i] <= h0p[i] + round_result_p[i][255:224];
                    state <= PHASE2B_INIT;
                end else begin
                    round <= round + 8'd1;
                    for (int i = 0; i < BATCH_SIZE; i++) begin
                        if (round < 8'd15)
                            wkp_pre[i] <= wp[i][round[3:0] + 4'd1] + k[round + 1];
                        else if (round == 8'd15)
                            wkp_pre[i] <= word_expand(wp[i][0], wp[i][1],
                                                      wp[i][9], wp[i][14]) + k[16];
                        else
                            wkp_pre[i] <= word_expand(wp[i][1], wp[i][2],
                                                      wp[i][10], wp[i][15]) + k[round + 1];
                        hp_pre[i] <= gp[i];
                    end
                end
            end

            // ── PHASE 2B INIT (nonces 8–15) ────────────────────────────────────
            PHASE2B_INIT: begin
                for (int i = 0; i < BATCH_SIZE; i++) begin
                    wp[i][0]  <= message[16];
                    wp[i][1]  <= message[17];
                    wp[i][2]  <= message[18];
                    wp[i][3]  <= {27'd0, (i[4:0] + 5'd8)};   // nonce 8..15
                    wp[i][4]  <= 32'h80000000;
                    wp[i][5]  <= 32'd0; wp[i][6]  <= 32'd0;
                    wp[i][7]  <= 32'd0; wp[i][8]  <= 32'd0;
                    wp[i][9]  <= 32'd0; wp[i][10] <= 32'd0;
                    wp[i][11] <= 32'd0; wp[i][12] <= 32'd0;
                    wp[i][13] <= 32'd0; wp[i][14] <= 32'd0;
                    wp[i][15] <= 32'd640;

                    h0p[i] <= phase1_h0; h1p[i] <= phase1_h1;
                    h2p[i] <= phase1_h2; h3p[i] <= phase1_h3;
                    h4p[i] <= phase1_h4; h5p[i] <= phase1_h5;
                    h6p[i] <= phase1_h6; h7p[i] <= phase1_h7;

                    ap[i] <= phase1_h0; bp[i] <= phase1_h1;
                    cp[i] <= phase1_h2; dp[i] <= phase1_h3;
                    ep[i] <= phase1_h4; fp[i] <= phase1_h5;
                    gp[i] <= phase1_h6; hp[i] <= phase1_h7;

                    wkp_pre[i] <= message[16] + 32'h428a2f98;
                    hp_pre[i]  <= phase1_h7;
                end
                round <= 8'd0;
                state <= PHASE2B_COMPUTE;
            end

            // ── PHASE 2B COMPUTE ────────────────────────────────────────────────
            PHASE2B_COMPUTE: begin
                for (int i = 0; i < BATCH_SIZE; i++) begin
                    {ap[i], bp[i], cp[i], dp[i],
                     ep[i], fp[i], gp[i], hp[i]} <= round_result_p[i];

                    if (round >= 8'd16) begin
                        for (int n = 0; n < 15; n++)
                            wp[i][n] <= wp[i][n+1];
                        wp[i][15] <= w_new_p[i];
                    end
                end

                if (round == 8'd63) begin
                    for (int i = 0; i < BATCH_SIZE; i++) begin
                        phase2_h[i][0] <= h0p[i] + round_result_p[i][255:224];
                        phase2_h[i][1] <= h1p[i] + round_result_p[i][223:192];
                        phase2_h[i][2] <= h2p[i] + round_result_p[i][191:160];
                        phase2_h[i][3] <= h3p[i] + round_result_p[i][159:128];
                        phase2_h[i][4] <= h4p[i] + round_result_p[i][127:96];
                        phase2_h[i][5] <= h5p[i] + round_result_p[i][95:64];
                        phase2_h[i][6] <= h6p[i] + round_result_p[i][63:32];
                        phase2_h[i][7] <= h7p[i] + round_result_p[i][31:0];
                    end
                    state <= PHASE3B_INIT;
                end else begin
                    round <= round + 8'd1;
                    for (int i = 0; i < BATCH_SIZE; i++) begin
                        if (round < 8'd15)
                            wkp_pre[i] <= wp[i][round[3:0] + 4'd1] + k[round + 1];
                        else if (round == 8'd15)
                            wkp_pre[i] <= word_expand(wp[i][0], wp[i][1],
                                                      wp[i][9], wp[i][14]) + k[16];
                        else
                            wkp_pre[i] <= word_expand(wp[i][1], wp[i][2],
                                                      wp[i][10], wp[i][15]) + k[round + 1];
                        hp_pre[i] <= gp[i];
                    end
                end
            end

            // ── PHASE 3B INIT (nonces 8–15 second hash) ─────────────────────────
            PHASE3B_INIT: begin
                for (int i = 0; i < BATCH_SIZE; i++) begin
                    wp[i][0]  <= phase2_h[i][0];
                    wp[i][1]  <= phase2_h[i][1];
                    wp[i][2]  <= phase2_h[i][2];
                    wp[i][3]  <= phase2_h[i][3];
                    wp[i][4]  <= phase2_h[i][4];
                    wp[i][5]  <= phase2_h[i][5];
                    wp[i][6]  <= phase2_h[i][6];
                    wp[i][7]  <= phase2_h[i][7];
                    wp[i][8]  <= 32'h80000000;
                    wp[i][9]  <= 32'd0; wp[i][10] <= 32'd0;
                    wp[i][11] <= 32'd0; wp[i][12] <= 32'd0;
                    wp[i][13] <= 32'd0; wp[i][14] <= 32'd0;
                    wp[i][15] <= 32'd256;

                    h0p[i] <= 32'h6a09e667; h1p[i] <= 32'hbb67ae85;
                    h2p[i] <= 32'h3c6ef372; h3p[i] <= 32'ha54ff53a;
                    h4p[i] <= 32'h510e527f; h5p[i] <= 32'h9b05688c;
                    h6p[i] <= 32'h1f83d9ab; h7p[i] <= 32'h5be0cd19;

                    ap[i] <= 32'h6a09e667; bp[i] <= 32'hbb67ae85;
                    cp[i] <= 32'h3c6ef372; dp[i] <= 32'ha54ff53a;
                    ep[i] <= 32'h510e527f; fp[i] <= 32'h9b05688c;
                    gp[i] <= 32'h1f83d9ab; hp[i] <= 32'h5be0cd19;

                    wkp_pre[i] <= phase2_h[i][0] + 32'h428a2f98;
                    hp_pre[i]  <= 32'h5be0cd19;
                end
                round <= 8'd0;
                state <= PHASE3B_COMPUTE;
            end

            // ── PHASE 3B COMPUTE ─────────────────────────────────────────────────
            PHASE3B_COMPUTE: begin
                for (int i = 0; i < BATCH_SIZE; i++) begin
                    {ap[i], bp[i], cp[i], dp[i],
                     ep[i], fp[i], gp[i], hp[i]} <= round_result_p[i];

                    if (round >= 8'd16) begin
                        for (int n = 0; n < 15; n++)
                            wp[i][n] <= wp[i][n+1];
                        wp[i][15] <= w_new_p[i];
                    end
                end

                if (round == 8'd63) begin
                    for (int i = 0; i < BATCH_SIZE; i++)
                        hout[i + BATCH_SIZE] <= h0p[i] + round_result_p[i][255:224];
                    write_count <= 5'd0;
                    state       <= WRITE_SETUP;
                end else begin
                    round <= round + 8'd1;
                    for (int i = 0; i < BATCH_SIZE; i++) begin
                        if (round < 8'd15)
                            wkp_pre[i] <= wp[i][round[3:0] + 4'd1] + k[round + 1];
                        else if (round == 8'd15)
                            wkp_pre[i] <= word_expand(wp[i][0], wp[i][1],
                                                      wp[i][9], wp[i][14]) + k[16];
                        else
                            wkp_pre[i] <= word_expand(wp[i][1], wp[i][2],
                                                      wp[i][10], wp[i][15]) + k[round + 1];
                        hp_pre[i] <= gp[i];
                    end
                end
            end

            // ── WRITE ──────────────────────────────────────────────────────────
            WRITE_SETUP: begin
                cur_mem_we         <= 1'b0;
                cur_mem_addr       <= output_addr + write_count;
                cur_mem_write_data <= hout[write_count];
                state              <= WRITE_ENABLE;
            end
            WRITE_ENABLE: begin
                cur_mem_we <= 1'b1;
                state      <= WRITE_NEXT;
            end
            WRITE_NEXT: begin
                cur_mem_we <= 1'b0;
                if (write_count == num_nonces - 1)
                    state <= DONE_STATE;
                else begin
                    write_count <= write_count + 5'd1;
                    state       <= WRITE_SETUP;
                end
            end

            DONE_STATE: begin
                cur_mem_we <= 1'b0;
                state      <= DONE_STATE;
            end

            default: state <= IDLE;

        endcase
    end
end

endmodule