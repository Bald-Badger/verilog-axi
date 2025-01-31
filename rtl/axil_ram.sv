/*

Copyright (c) 2018 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

// Language: Verilog 2001
import defines::*;
import mem_defines::*;

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * AXI4-Lite RAM
 */
module axil_ram #
(
	// Width of data bus in bits
	parameter DATA_WIDTH = 32,
	// Width of address bus in bits
	parameter ADDR_WIDTH = 16,
	// Width of wstrb (width of data bus in words)
	parameter STRB_WIDTH = (DATA_WIDTH/8),
	// Extra pipeline register on output
	parameter PIPELINE_OUTPUT = 0,
	// load the elf file into the mem on simulation
	parameter bootload = 0
) (
	input  wire						clk,
	input  wire						rst,

	input  wire [ADDR_WIDTH-1:0]	s_axil_awaddr,
	input  wire [2:0]				s_axil_awprot,
	input  wire						s_axil_awvalid,
	output wire						s_axil_awready,
	input  wire [DATA_WIDTH-1:0]	s_axil_wdata,
	input  wire [STRB_WIDTH-1:0]	s_axil_wstrb,
	input  wire						s_axil_wvalid,
	output wire						s_axil_wready,
	output wire [1:0]				s_axil_bresp,
	output wire						s_axil_bvalid,
	input  wire						s_axil_bready,
	input  wire [ADDR_WIDTH-1:0]	s_axil_araddr,
	input  wire [2:0]				s_axil_arprot,
	input  wire						s_axil_arvalid,
	output wire						s_axil_arready,
	output wire [DATA_WIDTH-1:0]	s_axil_rdata,
	output wire [1:0]				s_axil_rresp,
	output wire						s_axil_rvalid,
	input  wire						s_axil_rready
);

localparam	VALID_ADDR_WIDTH = ADDR_WIDTH - $clog2(STRB_WIDTH);
localparam	WORD_WIDTH = STRB_WIDTH;
localparam	WORD_SIZE = DATA_WIDTH/WORD_WIDTH;

reg mem_wr_en;
reg mem_rd_en;

reg s_axil_awready_reg = 1'b0, s_axil_awready_next;
reg s_axil_wready_reg = 1'b0, s_axil_wready_next;
reg s_axil_bvalid_reg = 1'b0, s_axil_bvalid_next;
reg s_axil_arready_reg = 1'b0, s_axil_arready_next;
reg [DATA_WIDTH-1:0] s_axil_rdata_reg = {DATA_WIDTH{1'b0}}, s_axil_rdata_next;
reg s_axil_rvalid_reg = 1'b0, s_axil_rvalid_next;
reg [DATA_WIDTH-1:0] s_axil_rdata_pipe_reg = {DATA_WIDTH{1'b0}};
reg s_axil_rvalid_pipe_reg = 1'b0;

// (* RAM_STYLE="BLOCK" *)
// reg [DATA_WIDTH-1:0] mem_init[0:(2**VALID_ADDR_WIDTH)-1];
reg [DATA_WIDTH-1:0] mem[0:(2**VALID_ADDR_WIDTH)-1];

wire [VALID_ADDR_WIDTH-1:0] s_axil_awaddr_valid = s_axil_awaddr >> (ADDR_WIDTH - VALID_ADDR_WIDTH);
wire [VALID_ADDR_WIDTH-1:0] s_axil_araddr_valid = s_axil_araddr >> (ADDR_WIDTH - VALID_ADDR_WIDTH);

assign s_axil_awready = s_axil_awready_reg;
assign s_axil_wready = s_axil_wready_reg;
assign s_axil_bresp = 2'b00;
assign s_axil_bvalid = s_axil_bvalid_reg;
assign s_axil_arready = s_axil_arready_reg;
assign s_axil_rdata = PIPELINE_OUTPUT ? s_axil_rdata_pipe_reg : s_axil_rdata_reg;
assign s_axil_rresp = 2'b00;
assign s_axil_rvalid = PIPELINE_OUTPUT ? s_axil_rvalid_pipe_reg : s_axil_rvalid_reg;

integer i, j;

integer fp, s;

// synthesis translate_off
initial begin
	if (bootload) begin
		case (BOOT_TYPE)
			BINARY_BOOT: begin
				fp = $fopen("riscy.elf","rb");
				if (fp == 0) begin
					$error("failed to open boot file\n");
					$stop();
				end

				for (i = 0; i < 2**VALID_ADDR_WIDTH; i++) begin
					mem[i] = 0;
				end

				s = $fread(mem, fp);
				$fclose(fp);

/*
				// RISCV binary should load to VA (in this case also PA) 0x10000
				for (i = 0; i < 2**VALID_ADDR_WIDTH - 20'h0x10000/4; i++) begin
					mem[20'h0x10000/4 + i] = mem_init [i];
				end

				for (i = 0; i < 20'h0x10000/4; i++) begin
					mem[i] = 0;
				end
*/
			end
			
			RARS_BOOT: begin
				$readmemh("instr.mc", mem);
			end

			default: begin
				$display("unkown boot type!");
				$stop();
			end
		endcase
	end else begin
		for (i = 0; i < 2**VALID_ADDR_WIDTH; i++) begin
			mem[i] = 0;
		end
	end
end
// synthesis translate_on

always @* begin
	mem_wr_en = 1'b0;

	s_axil_awready_next = 1'b0;
	s_axil_wready_next = 1'b0;
	s_axil_bvalid_next = s_axil_bvalid_reg && !s_axil_bready;

	if (s_axil_awvalid && s_axil_wvalid && (!s_axil_bvalid || s_axil_bready) && (!s_axil_awready && !s_axil_wready)) begin
		s_axil_awready_next = 1'b1;
		s_axil_wready_next = 1'b1;
		// delete cuz https://github.com/alexforencich/verilog-axi/pull/11/files
		// s_axil_bvalid_next = 1'b1;
		mem_wr_en = 1'b1;
	end

	// add cuz https://github.com/alexforencich/verilog-axi/pull/11/files
	if (s_axil_awvalid && s_axil_wvalid && (!s_axil_bvalid || s_axil_bready) && (s_axil_awready && s_axil_wready)) begin
		s_axil_bvalid_next = 1'b1;
	end

end

always @(posedge clk) begin
	s_axil_awready_reg <= s_axil_awready_next;
	s_axil_wready_reg <= s_axil_wready_next;
	s_axil_bvalid_reg <= s_axil_bvalid_next;

	for (i = 0; i < WORD_WIDTH; i = i + 1) begin
		if (mem_wr_en && s_axil_wstrb[i]) begin
			mem[s_axil_awaddr_valid][WORD_SIZE*i +: WORD_SIZE] <= s_axil_wdata[WORD_SIZE*i +: WORD_SIZE];
		end
	end

	if (rst) begin
		s_axil_awready_reg <= 1'b0;
		s_axil_wready_reg <= 1'b0;
		s_axil_bvalid_reg <= 1'b0;
	end
end

always @* begin
	mem_rd_en = 1'b0;

	s_axil_arready_next = 1'b0;
	s_axil_rvalid_next = s_axil_rvalid_reg && !(s_axil_rready || (PIPELINE_OUTPUT && !s_axil_rvalid_pipe_reg));

	if (s_axil_arvalid && (!s_axil_rvalid || s_axil_rready || (PIPELINE_OUTPUT && !s_axil_rvalid_pipe_reg)) && (!s_axil_arready)) begin
		s_axil_arready_next = 1'b1;
		s_axil_rvalid_next = 1'b1;

		mem_rd_en = 1'b1;
	end
end

always @(posedge clk) begin
	s_axil_arready_reg <= s_axil_arready_next;
	s_axil_rvalid_reg <= s_axil_rvalid_next;

	if (mem_rd_en) begin
		s_axil_rdata_reg <= mem[s_axil_araddr_valid];
	end

	if (!s_axil_rvalid_pipe_reg || s_axil_rready) begin
		s_axil_rdata_pipe_reg <= s_axil_rdata_reg;
		s_axil_rvalid_pipe_reg <= s_axil_rvalid_reg;
	end

	if (rst) begin
		s_axil_arready_reg <= 1'b0;
		s_axil_rvalid_reg <= 1'b0;
		s_axil_rvalid_pipe_reg <= 1'b0;
	end
end

endmodule

`resetall
