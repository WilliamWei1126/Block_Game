`timescale 1 ns / 1 ps
 
// =============================================================================
// raycaster_engine.sv
// DDA Raycaster with visual improvements:
//   - Side shading: Y-axis wall faces use a darker palette variant
//   - Distance fog: 3-level darkening based on perpWallDist
//   - Sky gradient: deep blue (top) ? light blue (horizon)
//   - Floor gradient: dark (horizon) ? grass green (near player)
// =============================================================================
 
module raycaster_engine (
    input  logic clk,
    input  logic reset,
    
    // AXI Registers (16.16 Fixed Point)
    input  logic signed [31:0] player_x, player_y, player_z,
    input  logic signed [31:0] dir_x, dir_y, plane_x, plane_y,
    
    // Map BRAM Port B (Read-Only)
    output logic [9:0]  map_addrb,
    input  logic [31:0] map_doutb,
    
    // Frame Buffer VRAM Port A (Write-Only)
    output logic [16:0] vram_w_addr,
    output logic [3:0]  vram_w_data,
    output logic        vram_we
);
 
    // =========================================================================
    // STATE MACHINE
    // =========================================================================
    enum logic [4:0] { 
        INIT, 
        CALC_RAY_MUL, CALC_RAY_ADD, 
        CALC_STEP, 
        DIV_DDX_INIT, WAIT_DDX, 
        DIV_DDY_INIT, WAIT_DDY, 
        SETUP_STEP_MUL, SETUP_STEP_ASSIGN,
        DDA_STEP, DDA_BRAM_WAIT, DDA_CHECK, CALC_DIST, 
        DIV_HEIGHT_INIT, WAIT_HEIGHT, 
        CALC_HEIGHT_MUL, CALC_HEIGHT_ADD, DRAW_COL
    } state;
 
    // =========================================================================
    // REGISTERS
    // =========================================================================
    logic [8:0] screen_x;
    logic [7:0] screen_y;
    
    logic signed [31:0] cameraX, rayDirX, rayDirY;
    logic signed [31:0] mapX, mapY;
    logic signed [31:0] sideDistX, sideDistY, deltaDistX, deltaDistY;
    logic signed [31:0] perpWallDist;
    
    logic signed [31:0] stepX, stepY; 
    logic hit, side;
    logic [3:0] hit_color;
    logic [6:0] depth_count; 
    logic [7:0] drawStart, drawEnd;
    logic [15:0] hit_fraction; 
    logic [31:0] abs_dir_x, abs_dir_y;
 
    // Pipeline registers
    logic signed [63:0] calc_ray_mul_x, calc_ray_mul_y;
    logic signed [63:0] setup_step_mul_x, setup_step_mul_y;
    logic signed [63:0] hit_frac_mul_res;
    logic signed [31:0] saved_line_height; 
    logic signed [31:0] nextMapX, nextMapY;
 
    // =========================================================================
    // HARDWARE DIVIDER (Vivado IP)
    // =========================================================================
    logic div_valid_in;
    logic div_valid_out;
    logic [63:0] div_num;
    logic [31:0] div_den;
    logic [95:0] div_result; 
 
    div_gen_0 hardware_divider (
      .aclk                       (clk),                                      
      .s_axis_divisor_tvalid      (div_valid_in),    
      .s_axis_divisor_tdata       (div_den),      
      .s_axis_dividend_tvalid     (div_valid_in),    
      .s_axis_dividend_tdata      (div_num),  
      .m_axis_dout_tvalid         (div_valid_out),      
      .m_axis_dout_tdata          (div_result)           
    );
 
    // =========================================================================
    // SHADE LOOKUP TABLE
    // Maps each palette color to a darker variant for Y-axis (side) wall hits.
    // Designed around the Minecraft palette in hdmi_text_controller_v1_0.sv:
    //   0=Sky, 1=Stone, 2=Grass, 3=Dirt, 4=Planks, 5=Leaves,
    //   6=Bricks, 7=Glass, 8=Water, 9=Sand, A=Gold, B=Lapis,
    //   C=Obsidian, D=Netherrack, E=Quartz, F=Error
    // =========================================================================
    function automatic [3:0] shade_dark(input logic [3:0] c);
        case (c)
            4'h0: shade_dark = 4'hB; // Sky       ? Lapis (deeper blue)
            4'h1: shade_dark = 4'hC; // Stone     ? Obsidian
            4'h2: shade_dark = 4'h5; // Grass     ? Leaves (dark green)
            4'h3: shade_dark = 4'hC; // Dirt      ? Obsidian
            4'h4: shade_dark = 4'h3; // Planks    ? Dirt
            4'h5: shade_dark = 4'hC; // Leaves    ? Obsidian
            4'h6: shade_dark = 4'hD; // Bricks    ? Netherrack
            4'h7: shade_dark = 4'h8; // Glass     ? Water (darker cyan)
            4'h8: shade_dark = 4'hB; // Water     ? Lapis (deep blue)
            4'h9: shade_dark = 4'h3; // Sand      ? Dirt
            4'hA: shade_dark = 4'h9; // Gold      ? Sand
            4'hB: shade_dark = 4'hC; // Lapis     ? Obsidian
            4'hC: shade_dark = 4'hC; // Obsidian  ? Obsidian (already darkest)
            4'hD: shade_dark = 4'hC; // Netherrack? Obsidian
            4'hE: shade_dark = 4'h1; // Quartz    ? Stone
            4'hF: shade_dark = 4'h6; // Error     ? Bricks
            default: shade_dark = 4'h0;
        endcase
    endfunction
 
    // Double-dark: apply shade_dark twice for very distant walls
    function automatic [3:0] shade_darker(input logic [3:0] c);
        shade_darker = shade_dark(shade_dark(c));
    endfunction
 
    // =========================================================================
    // MAIN STATE MACHINE
    // =========================================================================
    always_ff @(posedge clk) begin
        if (reset) begin
            state        <= INIT;
            screen_x     <= 0;
            vram_we      <= 0;
            div_valid_in <= 0;
        end else begin
            vram_we <= 0; 
            
            case (state)
 
                // ------------------------------------------------------------------
                // INIT: Start a new ray for the current screen column
                // ------------------------------------------------------------------
                INIT: begin
                    if (screen_x < 320) begin
                        // cameraX in [-1, +1] 16.16 fixed point
                        cameraX     <= ((screen_x << 17) / 320) - (1 << 16);
                        mapX        <= player_x[31:16];
                        mapY        <= player_y[31:16];
                        hit         <= 0;
                        depth_count <= 0;
                        state       <= CALC_RAY_MUL;
                    end else begin
                        screen_x <= 0; 
                    end
                end
 
                // ------------------------------------------------------------------
                // RAY DIRECTION: rayDir = dir + plane * cameraX
                // ------------------------------------------------------------------
                CALC_RAY_MUL: begin
                    calc_ray_mul_x <= 64'(plane_x) * 64'(cameraX);
                    calc_ray_mul_y <= 64'(plane_y) * 64'(cameraX);
                    state          <= CALC_RAY_ADD;
                end
                
                CALC_RAY_ADD: begin
                    rayDirX <= dir_x + calc_ray_mul_x[47:16];
                    rayDirY <= dir_y + calc_ray_mul_y[47:16];
                    state   <= CALC_STEP;
                end
 
                // ------------------------------------------------------------------
                // DELTA DIST: abs values of ray direction for division
                // ------------------------------------------------------------------
                CALC_STEP: begin
                    abs_dir_x <= (rayDirX < 0) ? -rayDirX : rayDirX;
                    abs_dir_y <= (rayDirY < 0) ? -rayDirY : rayDirY;
                    state     <= DIV_DDX_INIT;
                end
                
                DIV_DDX_INIT: begin
                    if (abs_dir_x < 32'd16) begin
                        // Near-zero X direction: ray is almost vertical, set huge deltaDist
                        deltaDistX <= 32'h0FFFFFFF;
                        state      <= DIV_DDY_INIT;
                    end else begin
                        div_num      <= 64'h0000000100000000; // 1.0 in 16.16 as 64-bit dividend
                        div_den      <= abs_dir_x;
                        div_valid_in <= 1'b1; 
                        state        <= WAIT_DDX;
                    end
                end
                
                WAIT_DDX: begin
                    div_valid_in <= 1'b0; 
                    if (div_valid_out) begin
                        deltaDistX <= div_result[63:32]; 
                        state      <= DIV_DDY_INIT;
                    end
                end
                
                DIV_DDY_INIT: begin
                    if (abs_dir_y < 32'd16) begin
                        deltaDistY <= 32'h0FFFFFFF;
                        state      <= SETUP_STEP_MUL;
                    end else begin
                        div_num      <= 64'h0000000100000000;
                        div_den      <= abs_dir_y;
                        div_valid_in <= 1'b1;
                        state        <= WAIT_DDY;
                    end
                end
                
                WAIT_DDY: begin
                    div_valid_in <= 1'b0;
                    if (div_valid_out) begin
                        deltaDistY <= div_result[63:32];
                        state      <= SETUP_STEP_MUL;
                    end
                end
 
                // ------------------------------------------------------------------
                // SETUP STEP: Compute initial side distances from player sub-cell pos
                // ------------------------------------------------------------------
                SETUP_STEP_MUL: begin
                    automatic logic signed [31:0] px_frac;
                    automatic logic signed [31:0] py_frac;
                    
                    px_frac = player_x & 32'h0000FFFF;
                    py_frac = player_y & 32'h0000FFFF;
                    
                    if (rayDirX < 0) begin
                        stepX          <= -1;
                        setup_step_mul_x <= 64'(px_frac) * 64'(deltaDistX);
                    end else begin
                        stepX          <= 1;
                        setup_step_mul_x <= 64'(32'h00010000 - px_frac) * 64'(deltaDistX);
                    end
                    
                    if (rayDirY < 0) begin
                        stepY          <= -1;
                        setup_step_mul_y <= 64'(py_frac) * 64'(deltaDistY);
                    end else begin
                        stepY          <= 1;
                        setup_step_mul_y <= 64'(32'h00010000 - py_frac) * 64'(deltaDistY);
                    end
                    state <= SETUP_STEP_ASSIGN;
                end
                
                SETUP_STEP_ASSIGN: begin
                    sideDistX <= setup_step_mul_x[47:16];
                    sideDistY <= setup_step_mul_y[47:16];
                    state     <= DDA_STEP;
                end
 
                // ------------------------------------------------------------------
                // DDA LOOP: March the ray through the map grid
                // ------------------------------------------------------------------
                DDA_STEP: begin
                    automatic logic signed [31:0] tempNextMapX;
                    automatic logic signed [31:0] tempNextMapY;
                
                    depth_count <= depth_count + 1;
                
                    if (depth_count > 64) begin
                        // Ray exceeded max depth - treat as sky-colored miss
                        hit       <= 1;
                        hit_color <= 4'h0;
                        state     <= CALC_DIST;
                    end else begin
                        tempNextMapX = mapX;
                        tempNextMapY = mapY;
                
                        if (sideDistX < sideDistY) begin
                            tempNextMapX = mapX + stepX;
                            sideDistX    <= sideDistX + deltaDistX;
                            side         <= 0; // X-axis wall face (bright)
                        end else begin
                            tempNextMapY = mapY + stepY;
                            sideDistY    <= sideDistY + deltaDistY;
                            side         <= 1; // Y-axis wall face (shaded)
                        end
                
                        nextMapX  <= tempNextMapX;
                        nextMapY  <= tempNextMapY;
                        map_addrb <= (tempNextMapY[4:0] * 32) + tempNextMapX[4:0];
                        state     <= DDA_BRAM_WAIT;
                    end
                end
                
                DDA_BRAM_WAIT: begin
                    // Wait one cycle for BRAM read latency
                    mapX  <= nextMapX;
                    mapY  <= nextMapY;
                    state <= DDA_CHECK;
                end
                
                DDA_CHECK: begin
                    if (nextMapX <= 0 || nextMapX >= 31 || nextMapY <= 0 || nextMapY >= 31) begin
                        // Hit map boundary - render as stone border
                        hit       <= 1;
                        hit_color <= 4'h1; // Stone
                        state     <= CALC_DIST;
                    end else if (map_doutb[3:0] > 0) begin
                        // Hit a solid block - capture block type from [3:0]
                        hit       <= 1;
                        hit_color <= map_doutb[3:0];
                        state     <= CALC_DIST;
                    end else begin
                        // Air - keep marching
                        state <= DDA_STEP;
                    end
                end
 
                // ------------------------------------------------------------------
                // DISTANCE + HEIGHT CALCULATION
                // ------------------------------------------------------------------
                CALC_DIST: begin
                    // Perpendicular wall distance (removes fisheye)
                    if (side == 0) perpWallDist <= sideDistX - deltaDistX;
                    else           perpWallDist <= sideDistY - deltaDistY;
                    state <= DIV_HEIGHT_INIT;
                end
                
                DIV_HEIGHT_INIT: begin
                    // Numerator: 240 * 65536 = 15728640 (screen half-height in 16.16)
                    div_num      <= {32'd0, 32'd15728640};
                    div_den      <= (perpWallDist <= 0) ? 32'd1 : perpWallDist;
                    div_valid_in <= 1'b1;
                    state        <= WAIT_HEIGHT;
                end
                
                WAIT_HEIGHT: begin
                    div_valid_in <= 1'b0;
                    if (div_valid_out) begin
                        saved_line_height <= div_result[63:32];
                        state             <= CALC_HEIGHT_MUL;
                    end
                end
 
                // ------------------------------------------------------------------
                // HIT FRACTION: Exact hit position along the wall for texture coord
                // ------------------------------------------------------------------
                CALC_HEIGHT_MUL: begin
                    automatic logic signed [31:0] safe_dist;
                    safe_dist = (perpWallDist <= 0) ? 32'd1 : perpWallDist;
                    
                    if (side == 0) hit_frac_mul_res <= 64'(safe_dist) * 64'(rayDirY);
                    else           hit_frac_mul_res <= 64'(safe_dist) * 64'(rayDirX);
                    
                    state <= CALC_HEIGHT_ADD;
                end
                
                CALC_HEIGHT_ADD: begin
                    automatic logic signed [31:0] exact_hit;
                    automatic logic signed [31:0] ds, de; 
                    automatic logic signed [31:0] pz;
                    automatic logic signed [31:0] z_offset;
                    
                    // Exact hit position (fractional part = wall texture U coord)
                    if (side == 0) exact_hit = player_y + hit_frac_mul_res[47:16];
                    else           exact_hit = player_x + hit_frac_mul_res[47:16];
                    hit_fraction <= exact_hit[15:0]; 
 
                    // Z offset for player eye height (look up/down effect)
                    pz       = player_z[31:16];
                    z_offset = (pz << 4) + (pz << 2); // pz * 20
 
                    // Draw start/end: center ± half wall height, shifted by z_offset
                    ds = 120 - (saved_line_height >> 1) + z_offset;
                    de = 120 + (saved_line_height >> 1) + z_offset;
                    
                    if      (ds < 0)   drawStart <= 8'd0;
                    else if (ds > 239) drawStart <= 8'd239;
                    else               drawStart <= ds[7:0];
                    
                    if      (de < 0)   drawEnd <= 8'd0;
                    else if (de > 239) drawEnd <= 8'd239;
                    else               drawEnd <= de[7:0];
                    
                    screen_y <= 0;
                    state    <= DRAW_COL;
                end
 
                // ------------------------------------------------------------------
                // DRAW_COL: Write pixels for this screen column top-to-bottom
                //
                // Visual improvements applied here:
                //   SKY GRADIENT  : Lapis blue (top) fades to light blue (horizon)
                //   WALL SHADING  : Y-axis faces rendered with shade_dark(hit_color)
                //   DISTANCE FOG  : 3-level darkening based on perpWallDist thresholds
                //   FLOOR GRADIENT: Dark stone near horizon, grass near player
                // ------------------------------------------------------------------
                DRAW_COL: begin
                    automatic logic [3:0] base_wall_color;
                    automatic logic [3:0] final_wall_color;
 
                    // --- Side shading: Y-axis faces are one shade darker ---
                    if (side == 1)
                        base_wall_color = shade_dark(hit_color);
                    else
                        base_wall_color = hit_color;
 
                    // --- Distance fog: 3 levels based on perpWallDist ---
                    // perpWallDist thresholds (16.16 fixed point):
                    //   0x00080000 = 8.0 units  ? very far
                    //   0x00040000 = 4.0 units  ? mid range
                    if      (perpWallDist > 32'h00080000)
                        final_wall_color = shade_darker(base_wall_color); // double-dark
                    else if (perpWallDist > 32'h00040000)
                        final_wall_color = shade_dark(base_wall_color);   // single-dark
                    else
                        final_wall_color = base_wall_color;               // full bright
 
                    vram_w_addr <= (screen_y * 320) + screen_x;
                    vram_we     <= 1'b1;
                    
                    if (screen_y < drawStart) begin
                        // --- Sky gradient ---
                        // Upper half of sky region: deep Lapis blue
                        // Lower half (near horizon):  light Sky blue
                        if (screen_y < (drawStart >> 1))
                            vram_w_data <= 4'hB; // Lapis deep blue
                        else
                            vram_w_data <= 4'h0; // Sky light blue
 
                    end else if (screen_y > drawEnd) begin
                        // --- Floor gradient ---
                        // Just below wall (horizon): dark Stone
                        // Far from wall (near player): Grass green
                        if (screen_y < (drawEnd + ((8'd239 - drawEnd) >> 1)))
                            vram_w_data <= 4'h1; // Stone (dark, near horizon)
                        else
                            vram_w_data <= 4'h2; // Grass (bright, near player)
 
                    end else begin
                        // --- Wall with side shading + distance fog ---
                        vram_w_data <= final_wall_color;
                    end
                    
                    if (screen_y == 239) begin
                        screen_x <= screen_x + 1;
                        state    <= INIT;
                    end else begin
                        screen_y <= screen_y + 1;
                    end
                end
 
            endcase
        end
    end
 
endmodule