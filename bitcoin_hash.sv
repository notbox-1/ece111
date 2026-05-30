module bitcoin_hash (input logic        clk, reset_n, start,
                     input logic [15:0] message_addr, output_addr,
                    output logic        done, mem_clk, mem_we,
                    output logic [15:0] mem_addr,
                    output logic [31:0] mem_write_data,
                     input logic [31:0] mem_read_data);

parameter num_nonces = 16;

//logic [ 4:0] state;
//logic [31:0] hout[num_nonces];

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

// Student to add rest of the code here


//SERIAL START
//states
typedef enum logic [4:0] {
    IDLE,
    READ_SETUP,
    READ_WAIT,
    READ_CAPTURE,

    PHASE1_INIT,
    PHASE1_COMPUTE,

    PHASE2_INIT,
    PHASE2_COMPUTE,

    PHASE3_INIT,
    PHASE3_COMPUTE,

    SAVE_HASH,

    WRITE_SETUP,
    WRITE_ENABLE,
    WRITE_NEXT,

    DONE_STATE
} state_t;

state_t state;

//19 fixed words from memory
logic [31:0] message [0:18];

// Final H0 output
logic [31:0] hout [0:num_nonces-1];



//optimizing: using most recent 16 words so we only use 512 bit instead of 2048
logic [31:0] w [0:15];


//working reg and cur hash reg
logic [31:0] a, b, c, d, e, f, g, h;
logic [31:0] h0, h1, h2, h3, h4, h5, h6, h7;






// Saved Phase 1,2 hash
logic [31:0] phase1_h0, phase1_h1, phase1_h2, phase1_h3;
logic [31:0] phase1_h4, phase1_h5, phase1_h6, phase1_h7;
logic [31:0] phase2_h0, phase2_h1, phase2_h2, phase2_h3;
logic [31:0] phase2_h4, phase2_h5, phase2_h6, phase2_h7;

//counter
logic [7:0]  round;
logic [4:0]  read_count;
logic [4:0]  nonce;
logic [4:0]  write_count;

//mem ontrol reg
logic [15:0] cur_mem_addr;
logic	cur_mem_we;
logic [31:0] cur_mem_write_data;


//helper signal
logic [31:0]  w_round;
logic [31:0]  w_new;
logic [255:0] round_result;



assign mem_clk = clk;
assign mem_addr = cur_mem_addr;
assign mem_we = cur_mem_we;
assign mem_write_data = cur_mem_write_data;

assign done = (state == DONE_STATE);


//for rounds 0-15, use the loaded message words
// for rounds 16-63, compute the next W value using rolling w[16] to optimize
assign w_new = word_expand(w[0], w[1], w[9], w[14]);
assign w_round = (round < 8'd16) ? w[round[3:0]] : w_new;
assign round_result = sha256_op(a, b, c, d, e, f, g, h, w_round, round);



//helper functions from part 1



function logic [15:0] determine_num_blocks(input logic [31:0] size);

  // Student to add function implementation
begin
    determine_num_blocks = (size >> 4) + (((size & 32'hf) <= 13) ? 1 : 2);
end
endfunction


// Right Rotation Example : right rotate input x by r
// Lets say input x = 1111 ffff 2222 3333 4444 6666 7777 8888
// lets say r = 4
// x >> r  will result in : 0000 1111 ffff 2222 3333 4444 6666 7777 
// x << (32-r) will result in : 8888 0000 0000 0000 0000 0000 0000 0000
// final right rotate expression is = (x >> r) | (x << (32-r));
// (0000 1111 ffff 2222 3333 4444 6666 7777) | (8888 0000 0000 0000 0000 0000 0000 0000)
// final value after right rotate = 8888 1111 ffff 2222 3333 4444 6666 7777
// Right rotation function
function logic [31:0] rightrotate(input logic [31:0] x,
                                  input logic [ 7:0] r);
begin
  rightrotate = (x >> r) | (x << (32 - r));
end
endfunction


// word expand
function logic [31:0] word_expand(input logic [31:0] wm16, wm15, wm7, wm2);
  logic [31:0] s0, s1;
begin
  s0 = rightrotate(wm15, 7) ^ rightrotate(wm15, 18) ^ (wm15 >> 3);
  s1 = rightrotate(wm2, 17) ^ rightrotate(wm2, 19) ^ (wm2 >> 10);
  word_expand = wm16 + s0 + wm7 + s1;
end
endfunction

// SHA256 hash round
function logic [255:0] sha256_op(input logic [31:0] a, b, c, d, e, f, g, h, w,
                                 input logic [7:0] t);
    logic [31:0] S1, S0, ch, maj, t1, t2; // internal signals
begin
    S1 = rightrotate(e, 6) ^ rightrotate(e, 11) ^ rightrotate(e, 25);
    // Student to add remaning code below
    // Refer to SHA256 discussion slides to get logic for this function
    ch = (e & f) ^ ((~e) & g);
    t1 = h + S1 + ch + k[t] + w;
    S0 = rightrotate(a, 2) ^ rightrotate(a, 13) ^ rightrotate(a, 22);
    maj = (a & b) ^ (a & c) ^ (b & c);
    t2 = S0 + maj;
    sha256_op = {t1 + t2, a, b, c, d + t1, e, f, g};
end
endfunction




/*
tead 1 bitccoin block header template
try 16 vals
compute the double hash for each nonce
save res

nonce: number of miners change repeatedly

so basically we try nonce, compute hash
if nonce good then success, if not then try another

*/

/*
1. idle
2. read set up
3. read capture, 
4. phase1 init, compute
5. phase2 init, compute
6. phase3 init, compute
7. save
8. write setup, enable, next, done


one run reads 19 words from mem, compute phase1 once, do phase 2,3 for each 16 nonces, then writes 16 results
*/

//clock edge pos or reset negedge
always_ff @(posedge clk or negedge reset_n) begin



	//if reset, set everything 0
	if(!reset_n) begin
		state <= IDLE;
		cur_mem_addr <= 16'd0;
		cur_mem_we <= 1'b0;
		cur_mem_write_data <= 32'd0;
		read_count  <= 5'd0;
		nonce <= 5'd0;
		write_count <= 5'd0;
		round <= 8'd0;
		h0 <= 32'd0; h1 <= 32'd0; h2 <= 32'd0; h3 <= 32'd0;
		h4 <= 32'd0; h5 <= 32'd0; h6 <= 32'd0; h7 <= 32'd0;
		a <= 32'd0; b <= 32'd0; c <= 32'd0; d <= 32'd0;
		e <= 32'd0; f <= 32'd0; g <= 32'd0; h <= 32'd0;
		
		phase1_h0 <= 32'd0; phase1_h1 <= 32'd0;
		phase1_h2 <= 32'd0; phase1_h3 <= 32'd0;
		phase1_h4 <= 32'd0; phase1_h5 <= 32'd0;
		phase1_h6 <= 32'd0; phase1_h7 <= 32'd0;
		
		
		phase2_h0 <= 32'd0; phase2_h1 <= 32'd0;
		phase2_h2 <= 32'd0; phase2_h3 <= 32'd0;
		phase2_h4 <= 32'd0; phase2_h5 <= 32'd0;
		phase2_h6 <= 32'd0; phase2_h7 <= 32'd0;
	end
	
	//fsm
	else begin
	//start case state
		case(state)
			IDLE: begin
				cur_mem_we <= 1'b0;
				//decimal
				cur_mem_write_data <= 32'd0;
				read_count <= 5'd0;
				nonce <= 5'd0;
				write_count <= 5'd0;
				round<= 8'd0;
				
				
				//next state
				if (start) begin
					state <= READ_SETUP;
				end
			end
			//memory read request
			READ_SETUP: begin
				cur_mem_we <= 1'b0;
				cur_mem_addr <= message_addr + read_count;
				state <= READ_WAIT;
			end
			
			//sync, wait one clock cycle
			READ_WAIT: begin
				state <= READ_CAPTURE;
			end
			
			//store the word returned from memory
			READ_CAPTURE: begin
				message[read_count] <= mem_read_data;
				//if all words used
				if (read_count == 5'd18) begin
					read_count <= 5'd0;
					state <= PHASE1_INIT;
				end
				//more words remain, += 1
				else begin
					read_count <= read_count + 5'd1;
					state <= READ_SETUP;
				end
			end
			
			
			//phase 1, init sha 256 in first block
			PHASE1_INIT: begin
			
				//load first 16 words
				for (int n = 0; n < 16; n++) begin
					w[n] <= message[n];
				end
				//load sha 256 initial constants
				h0 <= 32'h6a09e667;
				h1 <= 32'hbb67ae85;
				h2 <= 32'h3c6ef372;
				h3 <= 32'ha54ff53a;
				h4 <= 32'h510e527f;
				h5 <= 32'h9b05688c;
				h6 <= 32'h1f83d9ab;
				h7 <= 32'h5be0cd19;
				a <= 32'h6a09e667;
				b <= 32'hbb67ae85;
				c <= 32'h3c6ef372;
				d <= 32'ha54ff53a;
				e <= 32'h510e527f;
				f <= 32'h9b05688c;
				g<= 32'h1f83d9ab;
				h <= 32'h5be0cd19;
				round <= 8'd0;
				state <= PHASE1_COMPUTE;
			end
			//run all 64 sha 256 rounds for block 1
			PHASE1_COMPUTE: begin
				{a, b, c, d, e, f, g, h} <= round_result;
				if (round >= 8'd16) begin
					for (int n = 0; n < 15; n++) begin
						w[n] <= w[n+1];
					end
					w[15] <= w_new;
				end

				if (round == 8'd63) begin
					phase1_h0 <= h0 + round_result[255:224];
					phase1_h1 <= h1 + round_result[223:192];
					phase1_h2 <= h2 + round_result[191:160];
					phase1_h3 <= h3 + round_result[159:128];
					phase1_h4 <= h4 + round_result[127:96];
					phase1_h5 <=h5 + round_result[95:64];
					phase1_h6 <= h6 + round_result[63:32];
					phase1_h7 <= h7 + round_result[31:0];
					
					nonce <= 5'd0;
					state <= PHASE2_INIT;
				end
				else begin
					round <= round + 8'd1;
				end
			end
			
			//phase 2, 2nd block
			PHASE2_INIT: begin
				w[0] <= message[16];
				w[1] <= message[17];
				w[2] <= message[18];
				w[3] <= {27'd0, nonce};
				w[4] <= 32'h80000000;

				for (int i = 5; i < 15; i++)
					w[i] <= 32'd0;
				w[15] <= 32'd640;
				h0 <= phase1_h0;
				h1 <= phase1_h1;
				h2 <= phase1_h2;
				h3 <= phase1_h3;
				h4 <= phase1_h4;
				h5 <= phase1_h5;
				h6 <= phase1_h6;
				h7 <= phase1_h7;

				a<= phase1_h0;
				b <= phase1_h1;
				c <= phase1_h2;
				d <= phase1_h3;
				e <= phase1_h4;
				f <= phase1_h5;
				g <= phase1_h6;
				h <= phase1_h7;
				round <= 8'd0;
				state <= PHASE2_COMPUTE;
			end
			
			
			//comp remaining 64 rounds
			PHASE2_COMPUTE: begin
				{a, b, c, d, e, f, g, h} <= round_result;

				if (round >= 8'd16) begin
					 for (int n = 0; n < 15; n++) begin
						  w[n] <= w[n+1];
					 end
					 w[15] <= w_new;
				end

				if (round == 8'd63) begin
					 phase2_h0 <= h0 + round_result[255:224];
					 phase2_h1 <= h1 + round_result[223:192];
					 phase2_h2 <= h2 + round_result[191:160];
					 phase2_h3 <= h3 + round_result[159:128];
					 phase2_h4 <= h4 + round_result[127:96];
					 phase2_h5 <= h5 + round_result[95:64];
					 phase2_h6 <= h6 + round_result[63:32];
					 phase2_h7 <= h7 + round_result[31:0];

					 state <= PHASE3_INIT;
				end
				else begin
					 round <= round + 8'd1;
				end
			end
			
			//phase 3, start second sha 256
			PHASE3_INIT: begin
				w[0]<= phase2_h0;
				w[1] <= phase2_h1;
				w[2] <= phase2_h2;
				w[3] <= phase2_h3;
				w[4] <= phase2_h4;
				w[5] <= phase2_h5;
				w[6] <= phase2_h6;
				w[7] <= phase2_h7;
				w[8] <= 32'h80000000;
				w[9] <= 32'h00000000;
				w[10] <= 32'h00000000;
				w[11] <= 32'h00000000;
				w[12] <= 32'h00000000;
				w[13] <= 32'h00000000;
				w[14] <= 32'h00000000;
				w[15] <= 32'd256;

				h0 <= 32'h6a09e667;
				h1 <= 32'hbb67ae85;
				h2 <= 32'h3c6ef372;
				h3 <= 32'ha54ff53a;
				h4 <= 32'h510e527f;
				h5 <= 32'h9b05688c;
				h6 <= 32'h1f83d9ab;
				h7 <= 32'h5be0cd19;

				a <= 32'h6a09e667;
				b <= 32'hbb67ae85;
				c <= 32'h3c6ef372;
				d <= 32'ha54ff53a;
				e <= 32'h510e527f;
				f <= 32'h9b05688c;
				g <= 32'h1f83d9ab;
				h <= 32'h5be0cd19;

				round <= 8'd0;
				state <= PHASE3_COMPUTE;
			end
			
			
			PHASE3_COMPUTE: begin
				{a, b, c, d, e, f, g, h} <= round_result;

				if (round >= 8'd16) begin
					 for (int n = 0; n < 15; n++) begin
						  w[n] <= w[n+1];
					 end
					 w[15] <= w_new;
				end

				if (round == 8'd63) begin
					 // Part 2 only saves final H0 for each nonce.
					 hout[nonce] <= h0 + round_result[255:224];
					 state<= SAVE_HASH;
				end
				else begin
					 round <= round + 8'd1;
				end
			end
			
			//move to next nonce or star writing(decide what to do next)
			//see if there are more nonces or not and if its last nonce then go write setup
			SAVE_HASH: begin
				if (nonce == num_nonces - 1) begin
					 write_count <= 5'd0;
					 state <= WRITE_SETUP;
				end
				else begin
					 nonce <= nonce + 5'd1;
					 state <= PHASE2_INIT;
				end
			end
			
			//places address and data on memory buss
			WRITE_SETUP: begin
				cur_mem_we<= 1'b0;
				cur_mem_addr <= output_addr + write_count;
				cur_mem_write_data <= hout[write_count];
				state <= WRITE_ENABLE;
			
			
			end
			
			//enables write lol
			WRITE_ENABLE: begin
				cur_mem_we <= 1'b1;
				state <= WRITE_NEXT;
			end
			
			
			
			//finish write cycle
			WRITE_NEXT: begin
				cur_mem_we <= 1'b0;
				if (write_count == num_nonces - 1) begin
					 state <= DONE_STATE;
				end
				else begin
					 write_count <= write_count + 5'd1;
					 state       <= WRITE_SETUP;
				end
			end
			
			
			
			//done done donee
			DONE_STATE: begin
				cur_mem_we <= 1'b0;
				state <= DONE_STATE;
			end
			
			default: begin
				state <= IDLE;
			end
		endcase
	end

end

//SERIAL ENDD


endmodule
