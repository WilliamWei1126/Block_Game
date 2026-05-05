//Provided HDMI_Text_controller_v1_0 for HDMI AXI4 IP 
//Fall 2024 Distribution

//Modified 3/10/24 by Zuofu
//Updated 11/18/24 by Zuofu


`timescale 1 ns / 1 ps

module hdmi_text_controller_v1_0 #
(
    // Parameters of Axi Slave Bus Interface S00_AXI
    // Modify parameters as necessary for access of full VRAM range

    parameter integer C_AXI_DATA_WIDTH	= 32,
    parameter integer C_AXI_ADDR_WIDTH	= 14
)
(
    // Users to add ports here

    output logic hdmi_clk_n,
    output logic hdmi_clk_p,
    output logic [2:0] hdmi_tx_n,
    output logic [2:0] hdmi_tx_p,

    // User ports ends
    // Do not modify the ports beyond this line


    // Ports of Axi Slave Bus Interface AX
    input logic  axi_aclk,
    input logic  axi_aresetn,
    input logic [C_AXI_ADDR_WIDTH-1 : 0] axi_awaddr,
    input logic [2 : 0] axi_awprot,
    input logic  axi_awvalid,
    output logic  axi_awready,
    input logic [C_AXI_DATA_WIDTH-1 : 0] axi_wdata,
    input logic [(C_AXI_DATA_WIDTH/8)-1 : 0] axi_wstrb,
    input logic  axi_wvalid,
    output logic  axi_wready,
    output logic [1 : 0] axi_bresp,
    output logic  axi_bvalid,
    input logic  axi_bready,
    input logic [C_AXI_ADDR_WIDTH-1 : 0] axi_araddr,
    input logic [2 : 0] axi_arprot,
    input logic  axi_arvalid,
    output logic  axi_arready,
    output logic [C_AXI_DATA_WIDTH-1 : 0] axi_rdata,
    output logic [1 : 0] axi_rresp,
    output logic  axi_rvalid,
    input logic  axi_rready
);

//additional logic variables as necessary to support VGA, and HDMI modules.
   
    logic reset_ah;
    assign reset_ah = ~axi_aresetn;
    logic clk_25MHz, clk_125MHz, locked;
    logic hsync, vsync, vde;
    logic [9:0] drawX, drawY;
    logic [3:0] red, green, blue;
   
   // --- NEW SIGNALS FOR 3D VOXEL ENGINE ---
    // AXI to Hardware Registers (16.16 Fixed Point)
    logic signed [31:0] px, py, pz, dx, dy, plx, ply;
    
    // Map RAM Signals (True Dual Port)
   logic [9:0] map_addrb;
    logic [31:0] map_doutb;
    
    // Frame Buffer VRAM Signals (Simple Dual Port)
    logic [16:0] vram_w_addr, vram_r_addr;
    logic [3:0] vram_w_data, vram_r_data;
    logic vram_we;
// Instantiation of Axi Bus Interface AXI



hdmi_text_controller_v1_0_AXI # ( 
    .C_S_AXI_DATA_WIDTH(C_AXI_DATA_WIDTH),
    .C_S_AXI_ADDR_WIDTH(C_AXI_ADDR_WIDTH)
) hdmi_text_controller_v1_0_AXI_inst (
    .S_AXI_ACLK(axi_aclk),
    .S_AXI_ARESETN(axi_aresetn),
    .S_AXI_AWADDR(axi_awaddr),
    .S_AXI_AWPROT(axi_awprot),
    .S_AXI_AWVALID(axi_awvalid),
    .S_AXI_AWREADY(axi_awready),
    .S_AXI_WDATA(axi_wdata),
    .S_AXI_WSTRB(axi_wstrb),
    .S_AXI_WVALID(axi_wvalid),
    .S_AXI_WREADY(axi_wready),
    .S_AXI_BRESP(axi_bresp),
    .S_AXI_BVALID(axi_bvalid),
    .S_AXI_BREADY(axi_bready),
    .S_AXI_ARADDR(axi_araddr),
    .S_AXI_ARPROT(axi_arprot),
    .S_AXI_ARVALID(axi_arvalid),
    .S_AXI_ARREADY(axi_arready),
    .S_AXI_RDATA(axi_rdata),
    .S_AXI_RRESP(axi_rresp),
    .S_AXI_RVALID(axi_rvalid),
    .S_AXI_RREADY(axi_rready),
   
   
   // Custom Hookups for Raycaster
        .player_x(px), .player_y(py), .player_z(pz),
        .dir_x(dx), .dir_y(dy), .plane_x(plx), .plane_y(ply),
        
        .clk_125MHz(clk_125MHz),
        .raycaster_map_addr(map_addrb),
        .raycaster_map_data(map_doutb)//change
);


// 3. The Raycaster Engine (Replaces Color Mapper)
    raycaster_engine engine (
        .clk(axi_aclk), .reset(reset_ah),
        .player_x(px), .player_y(py), .player_z(pz),.dir_x(dx), .dir_y(dy), .plane_x(plx), .plane_y(ply),
        .map_addrb(map_addrb), .map_doutb(map_doutb),
        .vram_w_addr(vram_w_addr), .vram_w_data(vram_w_data), .vram_we(vram_we)
    );

    // 4. Frame Buffer VRAM (Simple Dual Port BRAM - Generated in Vivado)
    blk_mem_gen_1 vram (
        // --- PORT A (Written by Raycaster Engine) ---
        // --- PORT A (Written by Raycaster Engine) ---
        .clka(axi_aclk),
        .ena(1'b1),               
        .wea(vram_we),
        .addra(vram_w_addr),
        .dina(vram_w_data),       

        .dinb(4'b0000),
        .clkb(clk_25MHz),
        .enb(1'b1),              
        .web(1'b0),
        .addrb(vram_r_addr),           
        .doutb(vram_r_data)      
    );


    // Upscale Logic: Read from 320x240 memory for a 640x480 screen
    assign vram_r_addr = ((drawY >> 1) * 320) + (drawX >> 1);

    // Basic Color Palette Mapping (16 Minecraft-style colors)
    // Expands the 4-bit VRAM data into 12-bit RGB colors
    always_comb begin
        if (!vde) begin
            {red, green, blue} = 12'h000;
        end else begin
            case (vram_r_data)
                4'h0: {red, green, blue} = 12'h8CE; // 0: Sky (Light Blue)
                4'h1: {red, green, blue} = 12'h777; // 1: Stone (Gray)
                4'h2: {red, green, blue} = 12'h2A2; // 2: Grass (Green)
                4'h3: {red, green, blue} = 12'h642; // 3: Dirt (Brown)
                4'h4: {red, green, blue} = 12'h863; // 4: Wood Planks (Light Brown)
                4'h5: {red, green, blue} = 12'h151; // 5: Leaves (Dark Green)
                4'h6: {red, green, blue} = 12'hB33; // 6: Bricks (Red)
                4'h7: {red, green, blue} = 12'h9EE; // 7: Glass (Cyan)
                4'h8: {red, green, blue} = 12'h35C; // 8: Water (Translucent Blue)
                4'h9: {red, green, blue} = 12'hDC8; // 9: Sand (Yellowish)
                4'hA: {red, green, blue} = 12'hFD0; // A: Gold Block (Bright Yellow)
                4'hB: {red, green, blue} = 12'h13B; // B: Lapis/Blue (Deep Blue)
                4'hC: {red, green, blue} = 12'h102; // C: Obsidian (Dark Purple/Black)
                4'hD: {red, green, blue} = 12'h511; // D: Netherrack (Dark Red)
                4'hE: {red, green, blue} = 12'hEEE; // E: Quartz (White)
                4'hF: {red, green, blue} = 12'hF0F; // F: Error/Highlight (Magenta)
            endcase
        end
    end
//Instiante clocking wizard, VGA sync generator modules, and VGA-HDMI IP here. For a hint, refer to the provided
//top-level from the previous lab. You should get the IP to generate a valid HDMI signal (e.g. blue screen or gradient)
//prior to working on the text drawing.
    
    clk_wiz_0 clk_wiz (
        .clk_out1(clk_25MHz),
        .clk_out2(clk_125MHz),
        .reset(reset_ah),
        .locked(locked),
        .clk_in1(axi_aclk)
    );
    
    vga_controller vga (
        .pixel_clk(clk_25MHz),
        .reset(reset_ah),
        .hs(hsync),
        .vs(vsync),
        .active_nblank(vde),
        .drawX(drawX),
        .drawY(drawY)
    );    

    //Real Digital VGA to HDMI converter
    hdmi_tx_0 vga_to_hdmi (
        //Clocking and Reset
        .pix_clk(clk_25MHz),
        .pix_clkx5(clk_125MHz),
        .pix_clk_locked(locked),
        .rst(reset_ah),
        //Color and Sync Signals
        .red(red),
        .green(green),
        .blue(blue),
        .hsync(hsync),
        .vsync(vsync),
        .vde(vde),
        
        //aux Data (unused)
        .aux0_din(4'b0),
        .aux1_din(4'b0),
        .aux2_din(4'b0),
        .ade(1'b0),
        
        //Differential outputs
        .TMDS_CLK_P(hdmi_clk_p),          
        .TMDS_CLK_N(hdmi_clk_n),          
        .TMDS_DATA_P(hdmi_tx_p),         
        .TMDS_DATA_N(hdmi_tx_n)          
    );
    
   
// User logic ends

endmodule
