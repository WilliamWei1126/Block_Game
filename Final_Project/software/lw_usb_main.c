#include <stdio.h>
#include "platform.h"
#include "lw_usb/GenericMacros.h"
#include "lw_usb/GenericTypeDefs.h"
#include "lw_usb/MAX3421E.h"
#include "lw_usb/USB.h"
#include "lw_usb/usb_ch9.h"
#include "lw_usb/transfer.h"
#include "lw_usb/HID.h"

#include "xparameters.h"
#include "xil_printf.h"

#include "hdmi_text_controller.h"

#define STEP 0x00010000

// =============================================================================
// World cell encoding (matches raycaster_engine.sv):
//   bits [3:0]  : color  (palette index 0-15, see hdmi_text_controller_v1_0.sv)
//   bits [6:4]  : height (0 = air, 1-7 = column height in world units)
//   bits [31:7] : unused
//
// IMPORTANT: a cell with height == 0 is air regardless of the color bits.
// To place a visible block, both color AND height must be non-zero.
// =============================================================================
#define BLOCK(color, height)  (((height) & 0x7) << 4 | ((color) & 0xF))

static const int dir_step_x[8] = {
     1,  1,  0, -1, -1, -1,  0,  1
};

static const int dir_step_y[8] = {
     0,  1,  1,  1,  0, -1, -1, -1
};

extern HID_DEVICE hid_device;

static BYTE addr = 1; 	//hard-wired USB address
int facing;
const char* const devclasses[] = { " Uninitialized", " HID Keyboard", " HID Mouse", " Mass storage" };

BYTE GetDriverandReport() {
	BYTE i;
	BYTE rcode;
	BYTE device = 0xFF;
	BYTE tmpbyte;

	DEV_RECORD* tpl_ptr;
	xil_printf("Reached USB_STATE_RUNNING (0x40)\n");
	for (i = 1; i < USB_NUMDEVICES; i++) {
		tpl_ptr = GetDevtable(i);
		if (tpl_ptr->epinfo != NULL) {
			xil_printf("Device: %d", i);
			xil_printf("%s \n", devclasses[tpl_ptr->devclass]);
			device = tpl_ptr->devclass;
		}
	}
	//Query rate and protocol
	rcode = XferGetIdle(addr, 0, hid_device.interface, 0, &tmpbyte);
	if (rcode) {   //error handling
		xil_printf("GetIdle Error. Error code: ");
		xil_printf("%x \n", rcode);
	} else {
		xil_printf("Update rate: ");
		xil_printf("%x \n", tmpbyte);
	}
	xil_printf("Protocol: ");
	rcode = XferGetProto(addr, 0, hid_device.interface, &tmpbyte);
	if (rcode) {   //error handling
		xil_printf("GetProto Error. Error code ");
		xil_printf("%x \n", rcode);
	} else {
		xil_printf("%d \n", tmpbyte);
	}
	return device;
}

int facing = 4;   // start facing west

static void update_camera(void)
{
    switch (facing & 7) {
        case 0: // east
            hdmi_ctrl->camera_dir_x   = 0x00010000;
            hdmi_ctrl->camera_dir_y   = 0x00000000;
            hdmi_ctrl->camera_plane_x = 0x00000000;
            hdmi_ctrl->camera_plane_y = 0xFFFF570B;   // -0.66
            break;

        case 1: // southeast
            hdmi_ctrl->camera_dir_x   = 0x0000B505;   // +0.7071
            hdmi_ctrl->camera_dir_y   = 0x0000B505;   // +0.7071
            hdmi_ctrl->camera_plane_x = 0x00007779;   // +0.4667
            hdmi_ctrl->camera_plane_y = 0xFFFF8887;   // -0.4667
            break;

        case 2: // south
            hdmi_ctrl->camera_dir_x   = 0x00000000;
            hdmi_ctrl->camera_dir_y   = 0x00010000;
            hdmi_ctrl->camera_plane_x = 0x0000A8F5;   // +0.66
            hdmi_ctrl->camera_plane_y = 0x00000000;
            break;

        case 3: // southwest
            hdmi_ctrl->camera_dir_x   = 0xFFFF4AFB;   // -0.7071
            hdmi_ctrl->camera_dir_y   = 0x0000B505;   // +0.7071
            hdmi_ctrl->camera_plane_x = 0x00007779;   // +0.4667
            hdmi_ctrl->camera_plane_y = 0x00007779;   // +0.4667
            break;

        case 4: // west
            hdmi_ctrl->camera_dir_x   = 0xFFFF0000;   // -1.0
            hdmi_ctrl->camera_dir_y   = 0x00000000;
            hdmi_ctrl->camera_plane_x = 0x00000000;
            hdmi_ctrl->camera_plane_y = 0x0000A8F5;   // +0.66
            break;

        case 5: // northwest
            hdmi_ctrl->camera_dir_x   = 0xFFFF4AFB;   // -0.7071
            hdmi_ctrl->camera_dir_y   = 0xFFFF4AFB;   // -0.7071
            hdmi_ctrl->camera_plane_x = 0xFFFF8887;   // -0.4667
            hdmi_ctrl->camera_plane_y = 0x00007779;   // +0.4667
            break;

        case 6: // north
            hdmi_ctrl->camera_dir_x   = 0x00000000;
            hdmi_ctrl->camera_dir_y   = 0xFFFF0000;   // -1.0
            hdmi_ctrl->camera_plane_x = 0xFFFF570B;   // -0.66
            hdmi_ctrl->camera_plane_y = 0x00000000;
            break;

        case 7: // northeast
            hdmi_ctrl->camera_dir_x   = 0x0000B505;   // +0.7071
            hdmi_ctrl->camera_dir_y   = 0xFFFF4AFB;   // -0.7071
            hdmi_ctrl->camera_plane_x = 0xFFFF8887;   // -0.4667
            hdmi_ctrl->camera_plane_y = 0xFFFF8887;   // -0.4667
            break;
    }
}

static void turn_left_45(void)
{
    facing = (facing + 1) & 7;
    update_camera();
}

static void turn_right_45(void)
{
    facing = (facing + 7) & 7;
    update_camera();
}

static void move_forward(void)
{
    hdmi_ctrl->player_x += dir_step_x[facing] * STEP;
    hdmi_ctrl->player_y += dir_step_y[facing] * STEP;
}

static void move_backward(void)
{
    hdmi_ctrl->player_x -= dir_step_x[facing] * STEP;
    hdmi_ctrl->player_y -= dir_step_y[facing] * STEP;
}

static void strafe_right(void)
{
    int right_facing = (facing + 6) & 7;
    hdmi_ctrl->player_x += dir_step_x[right_facing] * STEP;
    hdmi_ctrl->player_y += dir_step_y[right_facing] * STEP;
}

static void strafe_left(void)
{
    int left_facing = (facing + 2) & 7;
    hdmi_ctrl->player_x += dir_step_x[left_facing] * STEP;
    hdmi_ctrl->player_y += dir_step_y[left_facing] * STEP;
}

void init_player(void)
{
    hdmi_ctrl->player_x = 0x00080000;   // 8.0
    hdmi_ctrl->player_y = 0x00080000;   // 8.0
    // player_z is hardwired to z=1.0 in the raycaster engine.
    // The address (0x2008) still exists for compatibility but writes are ignored.

    facing = 4;   // west
    update_camera();
}

// =============================================================================
// init_world: Variable-height test scene
//
// On spawn, player is at (8.0, 8.0) facing WEST (-X). With west-facing camera,
// "forward" is -X, and "right" is +Y. The staircase at x=5 puts heights 1..7
// directly across the player's field of view at depth ~3 units.
// =============================================================================
void init_world(void)
{
    // ---- Clear everything to air ----
    for (int y = 0; y < Width; y++) {
        for (int x = 0; x < Length; x++) {
            hdmi_ctrl->VRAM[x + Length * y] = 0x00000000;
        }
    }

    // ---- Inner border ring (height 5, stone color) ----
    // Tall enough to enclose the area but shorter than the auto-generated
    // boundary walls (height 7) at the absolute edge of the 32x32 map.
    for (int y = 0; y < Width; y++) {
        for (int x = 0; x < Length; x++) {
            if (x == 2 || x == Length - 2 || y == 2 || y == Width - 2) {
                hdmi_ctrl->VRAM[x + Length * y] = BLOCK(1, 5); // stone, h=5
            }
        }
    }

    // ---- Height staircase: 1..7 at x=5, across y=5..11 ----
    // Bricks (color 6) so all steps share one color and height differences
    // are obvious. Visible directly in front of player on spawn.
    hdmi_ctrl->VRAM[5 + Length * 5]  = BLOCK(6, 1); // h=1: top at eye level
    hdmi_ctrl->VRAM[5 + Length * 6]  = BLOCK(6, 2);
    hdmi_ctrl->VRAM[5 + Length * 7]  = BLOCK(6, 3);
    hdmi_ctrl->VRAM[5 + Length * 8]  = BLOCK(6, 4); // dead ahead
    hdmi_ctrl->VRAM[5 + Length * 9]  = BLOCK(6, 5);
    hdmi_ctrl->VRAM[5 + Length * 10] = BLOCK(6, 6);
    hdmi_ctrl->VRAM[5 + Length * 11] = BLOCK(6, 7); // h=7: max

    // ---- Short wall (h=1, eye level) you can look across ----
    // Place at x=10..15, y=12 - a low fence behind/right of the staircase
    for (int x = 10; x <= 15; x++) {
        hdmi_ctrl->VRAM[x + Length * 12] = BLOCK(2, 1); // grass, h=1
    }

    // ---- Tall scattered pillars (different colors, different heights) ----
    hdmi_ctrl->VRAM[20 + Length * 8]  = BLOCK(4, 7); // planks, max
    hdmi_ctrl->VRAM[24 + Length * 12] = BLOCK(0xA, 6); // gold, h=6
    hdmi_ctrl->VRAM[18 + Length * 20] = BLOCK(0xB, 5); // lapis, h=5
    hdmi_ctrl->VRAM[10 + Length * 25] = BLOCK(9, 4);   // sand, h=4

    // ---- Mid-height cluster (heights 2-3 mixed) ----
    hdmi_ctrl->VRAM[22 + Length * 22] = BLOCK(3, 2); // dirt, h=2
    hdmi_ctrl->VRAM[23 + Length * 22] = BLOCK(3, 3); // dirt, h=3
    hdmi_ctrl->VRAM[22 + Length * 23] = BLOCK(3, 3);
    hdmi_ctrl->VRAM[23 + Length * 23] = BLOCK(3, 2);

    // ---- Color/height variety row at y=15 ----
    hdmi_ctrl->VRAM[10 + Length * 15] = BLOCK(6, 2);   // bricks, h=2
    hdmi_ctrl->VRAM[12 + Length * 15] = BLOCK(0xA, 3); // gold,   h=3
    hdmi_ctrl->VRAM[14 + Length * 15] = BLOCK(8, 4);   // water,  h=4
    hdmi_ctrl->VRAM[16 + Length * 15] = BLOCK(0xE, 5); // quartz, h=5
    hdmi_ctrl->VRAM[18 + Length * 15] = BLOCK(4, 6);   // planks, h=6

    // ---- Lone tall obsidian pillar (max height, dark color) ----
    hdmi_ctrl->VRAM[27 + Length * 27] = BLOCK(0xC, 7);
}

//check if key is pressed
int is_key_pressed(BOOT_KBD_REPORT *kbdbuf, BYTE code){
	for(int i = 0; i < 6; i++){
		if(kbdbuf -> keycode[i] == code) return 1;
	}
	return 0;
}


int main() {
    init_platform();


   	BYTE rcode;
	BOOT_MOUSE_REPORT buf;		//USB mouse report
	BOOT_KBD_REPORT kbdbuf;

	BYTE runningdebugflag = 0;//flag to dump out a bunch of information when we first get to USB_STATE_RUNNING
	BYTE errorflag = 0; //flag once we get an error device so we don't keep dumping out state info
	BYTE device;

	xil_printf("initializing MAX3421E...\n");
	MAX3421E_init();
	xil_printf("initializing USB...\n");
	USB_init();

	int prev_left_arrow  = 0;
	int prev_right_arrow = 0;

	//initialize game
	init_world();
	xil_printf("test cell value: %x\n", hdmi_ctrl->VRAM[5 + Length * 8]);
	init_player();

	while (1) {
		MAX3421E_Task();
		USB_Task();
		if (GetUsbTaskState() == USB_STATE_RUNNING) {
			if (!runningdebugflag) {
				runningdebugflag = 1;
				device = GetDriverandReport();
			} else if (device == 1) {
				//run keyboard debug polling
				rcode = kbdPoll(&kbdbuf);
				if (rcode == hrNAK) {
					continue; //NAK means no new data
				} else if (rcode) {
					xil_printf("Rcode: ");
					xil_printf("%x \n", rcode);
					continue;
				}

				//game logic here
				//player move

				int left_arrow_now  = is_key_pressed(&kbdbuf, 80);
				int right_arrow_now = is_key_pressed(&kbdbuf, 79);

				int w_now = is_key_pressed(&kbdbuf, 0x1A);
				int a_now = is_key_pressed(&kbdbuf, 0x04);
				int s_now = is_key_pressed(&kbdbuf, 0x16);
				int d_now = is_key_pressed(&kbdbuf, 0x07);

				if (left_arrow_now && !prev_left_arrow) {
				    turn_left_45();
				}
				if (right_arrow_now && !prev_right_arrow) {
				    turn_right_45();
				}

				prev_left_arrow  = left_arrow_now;
				prev_right_arrow = right_arrow_now;

				if (w_now) move_forward();
				if (s_now) move_backward();
				if (a_now) strafe_left();
				if (d_now) strafe_right();

				prev_left_arrow  = left_arrow_now;
				prev_right_arrow = right_arrow_now;
				//check player standing on block
				xil_printf("player_x: %x\n", hdmi_ctrl->player_x);
				xil_printf("player_y: %x\n", hdmi_ctrl->player_y);


				xil_printf("keycodes: ");
				for (int i = 0; i < 6; i++) {
					xil_printf("%x ", kbdbuf.keycode[i]);
				}
				//Modify to output the last 2 keycodes on channel 2.
				xil_printf("\n");
			}
			/*
			else if (device == 2) {
				rcode = mousePoll(&buf);
				if (rcode == hrNAK) {
					//NAK means no new data
					continue;
				} else if (rcode) {
					xil_printf("Rcode: ");
					xil_printf("%x \n", rcode);
					continue;
				}
				xil_printf("X displacement: ");
				xil_printf("%d ", (signed char) buf.Xdispl);
				xil_printf("Y displacement: ");
				xil_printf("%d ", (signed char) buf.Ydispl);
				xil_printf("Buttons: ");
				xil_printf("%x\n", buf.button);
			}
			*/
		} else if (GetUsbTaskState() == USB_STATE_ERROR) {
			if (!errorflag) {
				errorflag = 1;
				xil_printf("USB Error State\n");
				//print out string descriptor here
			}
		} else //not in USB running state
		{

			xil_printf("USB task state: ");
			xil_printf("%x\n", GetUsbTaskState());
			if (runningdebugflag) {	//previously running, reset USB hardware just to clear out any funky state, HS/FS etc
				runningdebugflag = 0;
				MAX3421E_init();
				USB_init();
			}
			errorflag = 0;
		}

	}
    cleanup_platform();
	return 0;
}
