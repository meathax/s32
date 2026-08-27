"""Prevent future chats from routing games into ad-hoc RBF profiles."""

from pathlib import Path
from xml.etree import ElementTree
import unittest

from tools.gen_mra import GAMES, RBF_BY_PARENT


ROOT = Path(__file__).parents[1]
MRA_DIR = ROOT / "releases"


class GlobalProfileContractTests(unittest.TestCase):
    def test_declined_games_are_not_routed_or_emitted(self) -> None:
        removed = {
            "sonic", "sonicp",
            "kokoroj", "kokoroj2",
            "dbzvrvs", "f1en", "f1lap",
        }
        self.assertTrue(removed.isdisjoint(GAMES))
        self.assertIn("alien3", GAMES)
        self.assertIn("jpark", GAMES)
        self.assertIn("holo", GAMES)
        self.assertIn("spidman", GAMES)
        self.assertIn("slipstrm", GAMES)
        for promoted in ("brival", "darkedge", "radm", "radr"):
            self.assertIn(promoted, GAMES)
        for path in MRA_DIR.glob("*.mra"):
            root = ElementTree.parse(path).getroot()
            setname = root.findtext("setname", "")
            parent = root.findtext("parent", setname)
            self.assertNotIn(setname, removed, path.name)
            self.assertNotIn(parent, removed, path.name)

    def test_exactly_one_universal_quartus_profile_exists(self) -> None:
        """Every supported parent is routed through the universal revision."""
        for name in ("Arcade-SegaSystem32.qpf", "Arcade-SegaSystem32.qsf"):
            self.assertTrue((ROOT / name).is_file(), name)
        for name in ("segas32v25.qpf", "segas32v25.qsf"):
            self.assertFalse((ROOT / name).exists(), name)
        for obsolete in ("s32", "s32v25", "segas32", "s32GoldenAxe", "s32ArabianFight"):
            self.assertFalse((ROOT / f"{obsolete}.qpf").exists(), obsolete)
            self.assertFalse((ROOT / f"{obsolete}.qsf").exists(), obsolete)

    def test_universal_qsf_carries_both_hardware_shapes(self) -> None:
        qsf = (ROOT / "Arcade-SegaSystem32.qsf").read_text(encoding="utf-8")
        for macro in ("S32_PROFILE_STANDARD=1", "S32_GAME_ONLY_STD=1",
                      "S32_UNIVERSAL=1", "S32_V25_HW=1"):
            self.assertIn(f'VERILOG_MACRO "{macro}"', qsf)
        for macro in ("S32_JT12_MLAB_SHIFTS=1", "S32_V25_MLAB_FIFO=1",
                      "S32_V25_MLAB_EEPROM=1"):
            self.assertNotIn(f'VERILOG_MACRO "{macro}"', qsf)
        self.assertNotIn('VERILOG_MACRO "S32_REAL_V25=1"', qsf)
        self.assertNotIn('VERILOG_MACRO "S32_PROFILE_V25=1"', qsf)
        self.assertIn("QIP_FILE rtl/cpu/v25/v25.qip", qsf)
        self.assertIn('VERILOG_MACRO "MISTER_DISABLE_SHADOWMASK=1"', qsf)
        for legacy in ("S32_GA2_ONLY", "S32_GOLDENAXE_ONLY", "S32_ARABFIGHT_ONLY",
                       "S32_V25_GAME_ONLY", "S32_SONIC_ONLY"):
            self.assertNotIn(f'VERILOG_MACRO "{legacy}=1"', qsf)

    def test_universal_profile_contains_real_v25_and_hle_fallback(self) -> None:
        """The descriptor selects real V25 or HLE behavior at runtime."""
        top = (ROOT / "Arcade-SegaSystem32.sv").read_text(encoding="utf-8")
        core = (ROOT / "rtl/s32_core.sv").read_text(encoding="utf-8")
        qsf = (ROOT / "Arcade-SegaSystem32.qsf").read_text(encoding="utf-8")
        self.assertIn("active_board.has_v25          = board_desc.has_v25;", top)
        self.assertIn("s32_v25 v25 (", core)
        self.assertIn("QIP_FILE rtl/cpu/v25/v25.qip", qsf)
        self.assertIn('VERILOG_MACRO "S32_UNIVERSAL=1"', qsf)

    def test_profile_only_sources_are_mutually_exclusive(self) -> None:
        std = (ROOT / "Arcade-SegaSystem32.qsf").read_text(encoding="utf-8")
        shared = (ROOT / "files.qip").read_text(encoding="utf-8")
        self.assertIn("SYSTEMVERILOG_FILE rtl/prot/s32_prot.sv", std)
        self.assertIn("QIP_FILE rtl/cpu/v25/v25.qip", std)
        self.assertNotIn("SYSTEMVERILOG_FILE rtl/prot/s32_prot.sv", shared)
        self.assertNotIn("QIP_FILE rtl/cpu/v25/v25.qip", shared)

    def test_v60_cadence_fix_is_shared_by_both_profiles(self) -> None:
        """The Sonic timing fix must not become a profile-specific bypass."""
        core = (ROOT / "rtl/s32_core.sv").read_text(encoding="utf-8")
        files_qip = (ROOT / "files.qip").read_text(encoding="utf-8")
        self.assertIn("module s32_v60_exec_cadence", core)
        self.assertIn("s32_v60_exec_cadence v60_cadence", core)
        self.assertIn(".ce(v60_exec_ce)", core)
        self.assertIn("s32_v60_bus vbus", core)
        self.assertIn(".clk(clk_sys), .ce(ce_cpu), .rst(rst)", core)
        self.assertIn("SYSTEMVERILOG_FILE rtl/s32_core.sv", files_qip)
        for profile in (ROOT / "Arcade-SegaSystem32.qsf",):
            text = profile.read_text(encoding="utf-8")
            self.assertIn('VERILOG_MACRO "S32_PROFILE_STANDARD=1"', text)
            self.assertIn('VERILOG_MACRO "S32_SYSTEM32_ONLY=1"', text)

    def test_v60_wide_fetch_is_always_on_with_no_osd_option(self) -> None:
        """The wide instruction-fetch transport is present and hardwired on.

        Its 2026-08-14 removal routed every V60 prefetch through the shared
        ce-gated 16-bit bus, multiplying p0 SDRAM traffic and starving the
        tile renderer's p1 port on its ~10% scanline margin (measured:
        arabfgt water lines 51-53 displayed the stale line buffer on 19/448
        captured frames).  It is restored as a fixed capability: no OSD
        toggle, status[29] stays reserved, fast_v60 tied 1 in the top.
        """
        top = (ROOT / "Arcade-SegaSystem32.sv").read_text(encoding="utf-8")
        core = (ROOT / "rtl/s32_core.sv").read_text(encoding="utf-8")
        cpu = (ROOT / "rtl/cpu/v60/s32_v60.sv").read_text(encoding="utf-8")
        # Hardwired on in the top; no OSD entry, no status-bit consumer.
        self.assertIn(".fast_v60(1'b1)", top)
        self.assertNotIn("O[29],V60 Fetch", top)
        # status[29] survives only in the reserved-bit comment, never as logic.
        self.assertNotIn("status[29]", top.replace("status[29] is RESERVED", ""))
        # Core and CPU plumbing present, compiled in for production.
        self.assertIn("input             fast_v60", core)
        self.assertIn(".FAST_IFETCH(`FAST_IFETCH_EN)", core)
        self.assertIn(".if_req(if_req)", core)
        self.assertIn("parameter        FAST_IFETCH = 1'b0", cpu)
        self.assertIn("use_fast_ifetch = FAST_IFETCH && fast_ifetch && fetch_is_rom", cpu)
        # status[29] stays allocated so later options keep their meaning.
        self.assertIn("status[29] is RESERVED", top)
        self.assertIn("O[28:27],Scale,Normal,V-Integer,HV-Integer;", top)
        # The surviving PCB prefetch path is unchanged.
        self.assertIn(".clk(clk_sys), .ce(ce_cpu), .rst(rst)", core)
        self.assertIn("reg        seq_pd_valid;", cpu)
        self.assertIn("function automatic [4:0] exact_need_at", cpu)
        self.assertIn("wire [4:0] pf_high = pf_loop_hint ? 5'd24 : 5'd20", cpu)
        self.assertIn("task automatic complete_ea_now", cpu)
        self.assertIn("wire pf_ack = bus_ack && (bus_owner == OWN_PF);", cpu)
        self.assertNotIn("cpu_turbo", top)

    def test_sprite_throughput_and_publication_are_shared_by_both_profiles(self) -> None:
        """Busy lists keep two-stage pixels and never expose an in-flight FB."""
        core = (ROOT / "rtl/s32_core.sv").read_text(encoding="utf-8")
        sprite = (ROOT / "rtl/video/s32_sprite.sv").read_text(encoding="utf-8")
        self.assertIn(".present(vbl_start), .vblank(vbl_end)", core)
        self.assertIn("fb_rd_buf_r <= spr_scan_buf", core)
        self.assertIn("function automatic [1:0] choose_work_buf", sprite)
        self.assertIn("ready_buf <= work_buf", sprite)
        self.assertIn("scan_buf <= ready_buf", sprite)
        self.assertIn("fb_wr_buf <= is_multi32", sprite)
        self.assertNotIn("R_PIXEL_DATA, R_DONE", sprite)
        self.assertIn("pixel_pen8     <= pixrow", sprite)
        self.assertIn("rs <= R_EMIT", sprite)
        for profile in (ROOT / "Arcade-SegaSystem32.qsf",):
            text = profile.read_text(encoding="utf-8")
            self.assertIn('VERILOG_MACRO "S32_PROFILE_STANDARD=1"', text)

    def test_production_pause_is_mra_mappable_without_reusing_osd_bits(self) -> None:
        top = (ROOT / "Arcade-SegaSystem32.sv").read_text(encoding="utf-8")
        self.assertNotIn("O[12],Pause", top)
        self.assertNotIn("Analog Aim Invert", top)
        self.assertNotIn("wire pause = status[12]", top)
        self.assertIn("wire pause = joystick_0[14] | joystick_1[14]", top)
        for enable in ("cpu", "z80", "fm", "pcm"):
            self.assertIn(f"wire ce_{enable}_run = ce_{enable} & ~pause", top)
        self.assertIn(".pause(pause)", top)
        self.assertIn("assign AUDIO_L = pause ? 16'sd0 : aud_l", top)
        self.assertIn("assign AUDIO_R = pause ? 16'sd0 : aud_r", top)

    def test_every_emitted_mra_routes_to_a_known_profile(self) -> None:
        self.assertEqual(RBF_BY_PARENT, {parent: "Arcade-SegaSystem32" for parent in GAMES})
        seen = set()
        for path in MRA_DIR.glob("*.mra"):
            root = ElementTree.parse(path).getroot()
            parent = root.findtext("parent") or root.findtext("setname")
            if parent not in GAMES:
                continue
            seen.add(parent)
            expected_rbf = RBF_BY_PARENT[parent]
            self.assertEqual(root.findtext("rbf"), expected_rbf, path.name)
        self.assertTrue(seen)
        self.assertTrue(seen <= set(GAMES))

    def test_romboot_ga2_qualification_uses_descriptor_boundary(self) -> None:
        """A protection selector must not classify standard games as GA2."""
        text = (ROOT / "verif/common/tb_core_romboot.sv").read_text(
            encoding="utf-8")
        self.assertIn("ga2_qualification", text)
        self.assertIn("((b0 & 8'h06) == 8'h02)", text)
        self.assertIn(
            "board.v25_table,\n             ga2_qualification, board.has_adc, board.has_ppi",
            text,
        )
        self.assertNotIn("b2 != 1 && frames >= 70 && spr_px == 0", text)

    def test_romboot_attract_gate_requires_verilator_screenshot(self) -> None:
        """Promotion must be backed by a non-black frame from this run."""
        text = (ROOT / "verif/common/tb_core_romboot.sv").read_text(
            encoding="utf-8")
        self.assertIn("REQUIRE_VERILATOR_SCREENSHOT", text)
        self.assertIn("dump_nonblack_seen", text)
        self.assertIn("VERILATOR SCREENSHOT FAIL", text)

    def test_positional_gun_controls_are_present_without_framebuffer_blend(self) -> None:
        text = (ROOT / "Arcade-SegaSystem32.sv").read_text(encoding="utf-8")
        core = (ROOT / "rtl/s32_core.sv").read_text(encoding="utf-8")
        io = (ROOT / "rtl/io/s32_io.sv").read_text(encoding="utf-8")
        prot = (ROOT / "rtl/prot/s32_prot.sv").read_text(encoding="utf-8")
        fb_if = (ROOT / "rtl/mem/s32_fb_if.sv").read_text(encoding="utf-8")
        snac = (ROOT / "rtl/io/s32_guncon_snac.sv").read_text(encoding="utf-8")
        lightgun = (ROOT / "rtl/io/s32_lightgun.sv").read_text(encoding="utf-8")
        jpark_gain = (ROOT / "rtl/io/s32_jpark_gun_gain.sv").read_text(encoding="utf-8")
        overlay = (ROOT / "rtl/video/s32_lightgun_overlay.sv").read_text(encoding="utf-8")
        qip = (ROOT / "files.qip").read_text(encoding="utf-8")
        regression = (ROOT / "verif/run_regression.ps1").read_text(encoding="utf-8")
        romboot = (ROOT / "verif/common/tb_core_romboot.sv").read_text(
            encoding="utf-8"
        )
        combined = "\n".join((text, core, io, prot, fb_if, snac, romboot))
        self.assertIn("gun_aim", combined)
        self.assertIn("coin_swap", combined)
        self.assertIn("s32_guncon_snac", combined)
        self.assertIn("module s32_lightgun", lightgun)
        self.assertIn("module s32_jpark_gun_gain", jpark_gain)
        self.assertIn("module s32_lightgun_overlay", overlay)
        self.assertIn(".ps2_mouse(ps2_mouse)", text)
        self.assertIn("ps2_mouse_dx9 = $signed({ps2_mouse[4], ps2_mouse[15:8]})", text)
        self.assertIn("ps2_mouse_dy9 = $signed({ps2_mouse[5], ps2_mouse[23:16]})", text)
        self.assertIn("s32_lightgun #(.DEFAULT_WIDTH(320), .DEFAULT_HEIGHT(224)) generic_lightgun_p1", text)
        self.assertIn("s32_lightgun #(.DEFAULT_WIDTH(320), .DEFAULT_HEIGHT(224)) generic_lightgun_p2", text)
        self.assertIn('"h0O[8],Sinden Borders,Off,On;"', text)
        self.assertIn('"h0O[34],Gun Crosshair,Off,On;"', text)
        self.assertIn('"h0O[37:36],Gun Sensitivity,Normal,High,Low,Lowest;"', text)
        self.assertIn("SYSTEMVERILOG_FILE rtl/io/s32_lightgun.sv", qip)
        self.assertIn("SYSTEMVERILOG_FILE rtl/io/s32_jpark_gun_gain.sv", qip)
        self.assertIn("SYSTEMVERILOG_FILE rtl/video/s32_lightgun_overlay.sv", qip)
        self.assertIn('Run-HdlTest "t35_lightgun"', regression)
        self.assertIn('Run-HdlTest "t35_jpark_gun_gain"', regression)
        self.assertIn('Run-HdlTest "t35_lightgun_overlay"', regression)
        self.assertIn('Run-HdlTest "t35_lightgun_overlay_native"', regression)
        self.assertNotIn("s32_gun_aim", combined)
        self.assertIn(
            "wire gun_snac_supported = active_board.gun_aim && !active_board.coin_swap;",
            text,
        )
        self.assertIn(
            "wire p1_snac_mode = gun_snac_supported && (status[31:30] == 2'b01);",
            text,
        )
        self.assertIn(
            "wire p2_snac_mode = gun_snac_supported && (status[33:32] == 2'b01);",
            text,
        )
        self.assertIn(
            '"h0O[31:30],P1 Gun Input,Stick/USB Gun/Sinden,SNAC Port 1;"',
            text,
        )
        self.assertIn(
            '"h0o[1:0],P2 Gun Input,Stick/USB Gun/Sinden,SNAC Port 2;"',
            text,
        )
        self.assertNotIn('"P1O[31:30],P1 Gun Input', text)
        self.assertIn("? snac_p1_gun_x[9:2] : host_gun_p1_x", text)
        self.assertIn("? snac_p1_gun_y : host_gun_p1_y", text)
        self.assertIn("? snac_p2_gun_x[9:2] : host_gun_p2_x", text)
        self.assertIn("? snac_p2_gun_y : host_gun_p2_y", text)
        self.assertIn(
            "wire jpark_gun_gain_enable = active_board.gun_aim && !active_board.coin_swap;",
            text,
        )
        self.assertIn("enable ? centered_half(p1_x_in) : p1_x_in", jpark_gain)
        self.assertIn("assign sim_gun_p1_x = gun_p1_x[7:0]", romboot)
        self.assertIn("assign sim_gun_p2_y = gun_p2_y[7:0]", romboot)
        self.assertNotIn("alien3_stick", combined)
        self.assertNotIn("alien3_gun_profile", combined)
        self.assertNotIn("alien3_hud_blend", combined)
        self.assertNotIn("rd_blend_buf", combined)
        self.assertIn("wire [7:0] alien3_p1a = {6'h3f, gun_p1a[1]", text)
        self.assertIn("wire [7:0] jpark_p1a = {7'h7f, gun_p1a[0]}", text)
        self.assertIn("wire snac_p1_gun = p1_snac_mode && snac_p1_connected", text)
        self.assertIn("~(VGA_HS ^ VGA_VS) : 1'b1", text)
        self.assertIn("wire gun_snac_trigger_p1 = snac_p1_gun && snac_p1_buttons[13]", text)
        self.assertIn("wire gun_snac_button2_p1 = snac_p1_gun && snac_p1_buttons[12]", text)
        self.assertIn("wire gun_snac_coin_p2 = snac_p2_gun && snac_p2_buttons[14]", text)
        self.assertIn("joystick_0[11] | gun_snac_coin_p1", text)
        self.assertIn("joystick_1[11] | gun_snac_coin_p2", text)
        for removed in (
            "has_track", "PROT_SONIC", "s32_trackball_stick", "s32_upd4701",
        ):
            self.assertNotIn(removed, combined)

    def test_runtime_input_options_are_descriptor_gated(self) -> None:
        top = (ROOT / "Arcade-SegaSystem32.sv").read_text(encoding="utf-8")
        core = (ROOT / "rtl/s32_core.sv").read_text(encoding="utf-8")
        io = (ROOT / "rtl/io/s32_io.sv").read_text(encoding="utf-8")
        self.assertIn('"h0O[31:30],P1 Gun Input,', top)
        self.assertIn('"h0o[1:0],P2 Gun Input,', top)
        self.assertIn('"h0O[8],Sinden Borders,', top)
        self.assertIn('"h0O[34],Gun Crosshair,', top)
        self.assertIn('"h0O[37:36],Gun Sensitivity,', top)
        self.assertIn('"h2O[35],Invert Trackball Y,Off,On;"', top)
        self.assertIn(
            ".status_menumask({13'd0, (active_board.prot_sel == PROT_SONIC), ~status[9], active_board.gun_aim})",
            top,
        )
        self.assertIn(
            "wire trackball_y_invert = (active_board.prot_sel == PROT_SONIC) && status[35];",
            top,
        )
        self.assertIn("input              trackball_y_invert,", core)
        self.assertIn(".invert_y(trackball_y_invert)", core)
        self.assertIn(
            "wire signed [8:0] y0_delta = axis_delta(p1_y, p1_dir[3], p1_dir[2], invert_y);",
            io,
        )
        self.assertIn(
            "wire signed [8:0] mouse_y_delta = invert_y ? -mouse_dy : mouse_dy;",
            io,
        )

    def test_standard_fighting_inputs_are_descriptor_selected(self) -> None:
        """Dark Edge upper buttons must not use GA2's P3/P4 wiring."""
        text = (ROOT / "Arcade-SegaSystem32.sv").read_text(encoding="utf-8")
        self.assertIn(
            "active_board.prot_sel == PROT_DARKEDGE) ? darkedge_p1a",
            text,
        )
        self.assertIn("wire [7:0] darkedge_ppi_pb", text)
        self.assertIn("wire [7:0] brival_ppi_pb", text)
        self.assertIn("wire brival_inputs = active_board.prot_sel == PROT_BRIVAL", text)
        self.assertIn(
            "wire darkedge_inputs = active_board.prot_sel == PROT_DARKEDGE",
            text,
        )
        self.assertIn(
            ".ppi_pa(core_ppi_pa), .ppi_pb(core_ppi_pb), .ppi_pc(core_ppi_pc)",
            text,
        )

    def test_production_video_path_includes_core_side_crt_adjust(self) -> None:
        text = (ROOT / "Arcade-SegaSystem32.sv").read_text(encoding="utf-8")
        files_qip = (ROOT / "files.qip").read_text(encoding="utf-8")
        regression = (ROOT / "verif/run_regression.ps1").read_text(encoding="utf-8")
        shell_regression = (ROOT / "verif/run_regression.sh").read_text(encoding="utf-8")
        self.assertIn('"O[9],CRT Adjust,Off,On;"', text)
        self.assertIn('"H1O[14:10],CRT H-Size,', text)
        self.assertIn('"H1O[21:15],CRT H-Position,', text)
        self.assertIn('"H1O[26:22],CRT V-Shift,', text)
        self.assertIn(
            ".status_menumask({13'd0, (active_board.prot_sel == PROT_SONIC), ~status[9], active_board.gun_aim})",
            text,
        )
        self.assertIn("crt_adjust #(\n", text)
        self.assertIn("crt_adjust_active", text)
        self.assertIn("crt_hs_ref_rise", text)
        self.assertIn(".vb_in     (core_vb)", text)
        self.assertIn(".AW        (10)", text)
        self.assertIn("crt_hpos_native", text)
        self.assertIn("- 9'sd97", text)
        self.assertIn('"O[28:27],Scale,Normal,V-Integer,HV-Integer;"', text)
        self.assertIn("video_freak s32_video_freak", text)
        self.assertIn("status[28:27]", text)
        self.assertIn("SYSTEMVERILOG_FILE rtl/crt_adjust.sv", files_qip)
        self.assertIn('"rtl/crt_adjust.sv",', regression)
        self.assertIn("rtl/video/*.sv rtl/crt_adjust.sv rtl/audio/", shell_regression)
        self.assertIn("wire hdmi_output_active", text)
        self.assertIn("!hdmi_output_active", text)
        self.assertIn("scandoubler_fx == 3'd0", text)
        self.assertIn("assign CE_PIXEL = crt_adjust_active ? crt_rd_ce : ce_pix_core;", text)
        self.assertIn("assign VGA_HS = crt_adjust_active ? crt_hs : core_hs;", text)
        self.assertIn("assign VGA_VS = crt_adjust_active ? crt_vs : core_vs;", text)

    def test_video_output_contract_covers_direct_analog_crt_and_hdmi(self) -> None:
        top = (ROOT / "Arcade-SegaSystem32.sv").read_text(encoding="utf-8")
        sys_top = (ROOT / "sys/sys_top.v").read_text(encoding="utf-8")
        files_qip = (ROOT / "files.qip").read_text(encoding="utf-8")
        sys_qip = (ROOT / "sys/sys.qip").read_text(encoding="utf-8")

        for signal in (
            "CLK_VIDEO", "CE_PIXEL", "VIDEO_ARX", "VIDEO_ARY",
            "VGA_R", "VGA_G", "VGA_B", "VGA_HS", "VGA_VS", "VGA_DE",
            "VGA_SL", "VGA_SCALER", "VGA_DISABLE", "HDMI_WIDTH",
            "HDMI_HEIGHT", "HDMI_FREEZE", "HDMI_BLACKOUT", "HDMI_BOB_DEINT",
        ):
            self.assertIn(signal, top)
        self.assertIn("assign CLK_VIDEO = clk_sys;", top)
        self.assertIn("assign VGA_SCALER = 0;", top)
        self.assertIn("assign VGA_DISABLE = 0;", top)
        self.assertIn("assign HDMI_BLACKOUT = 1'b1;", top)
        self.assertIn("wire    direct_video = cfg[10];", sys_top)
        self.assertIn(".HDMI_WIDTH(direct_video ? 12'd0 : hdmi_width)", sys_top)
        self.assertIn(".HDMI_HEIGHT(direct_video ? 12'd0 : hdmi_height)", sys_top)
        self.assertIn("cyclonev_clkselect hdmi_clk_sw", sys_top)
        self.assertIn("~vga_fb & direct_video", sys_top)
        self.assertIn("`ifndef MISTER_DUAL_SDRAM", sys_top)
        self.assertIn("vga_out vga_out", sys_top)
        self.assertIn("ascal", sys_top)
        self.assertIn("scanlines #(0) VGA_scanlines", sys_top)
        self.assertIn("swblack  (hdmi_blackout)", sys_top)
        self.assertIn('QIP_FILE sys/sys.qip', files_qip)
        for source in ("video_freak.sv", "scanlines.v", "vga_out.sv", "yc_out.sv"):
            self.assertIn(source, sys_qip)

    def test_universal_memory_storage_targets_m10k(self) -> None:
        core = (ROOT / "rtl/s32_core.sv").read_text(encoding="utf-8")
        v25 = (ROOT / "rtl/cpu/v25/s32_v25_cpu.sv").read_text(
            encoding="utf-8")
        self.assertIn(
            '(* ramstyle = "M10K, no_rw_check" *) reg [CACHE_WIDTH-1:0] cache_mem',
            core,
        )
        self.assertEqual(v25.count('ram_block_type = "M10K"'), 2)

    def test_default_regressions_do_not_force_retired_mlab_branches(self) -> None:
        for relative in ("verif/run_regression.ps1", "verif/run_regression.sh"):
            runner = (ROOT / relative).read_text(encoding="utf-8")
            for macro in ("S32_JT12_MLAB_SHIFTS", "S32_V25_MLAB_FIFO",
                          "S32_V25_MLAB_EEPROM"):
                self.assertNotIn(macro, runner, relative)

    def test_modelsim_isolates_incompatible_v25_donor_without_losing_gates(self) -> None:
        runner = (ROOT / "verif/run_regression.ps1").read_text(
            encoding="utf-8")
        self.assertIn("function Assert-V25SourceClosure", runner)
        self.assertIn("V25 UNIVERSAL SOURCE CLOSURE: PASS", runner)
        self.assertNotIn("$V25Sources", runner)
        self.assertNotIn('"-mfcu"', runner)
        self.assertIn("ModelSim full-core lint (compatible HLE shape)", runner)
        self.assertIn("-ModelSimBin $ModelSimDirectory", runner)
        for gate in (
            "verif/v25/run_v25_firmware.ps1",
            "verif/v25/run_v25_integration.ps1",
            "verif/v25/run_v25_sdram.ps1",
        ):
            self.assertIn(gate, runner)

    def test_sound_benches_use_the_external_wave_ram_contract(self) -> None:
        runner = (ROOT / "verif/run_regression.ps1").read_text(
            encoding="utf-8")
        self.assertGreaterEqual(
            runner.count("verif/common/s32_wave_ram_model.sv"), 2)
        for name in ("tb_soundsys_z80.sv", "tb_soundsys_shared.sv"):
            bench = (ROOT / "verif/common" / name).read_text(encoding="utf-8")
            self.assertIn("s32_wave_ram_model wave_mem", bench, name)
            self.assertIn(".wave_rd_req(wave_rd_req)", bench, name)
            self.assertIn(".wave_wr_req(wave_wr_req)", bench, name)
            self.assertNotIn("dut.rf5c68.wave_ram", bench, name)

    def test_real_v25_runners_use_native_safe_build_run_handoff(self) -> None:
        for stem, marker in (
            ("integration", "V25_INTEGRATION"),
            ("sdram", "V25_SDRAM"),
        ):
            ps1 = (ROOT / "verif/v25" / f"run_v25_{stem}.ps1").read_text(
                encoding="utf-8")
            shell = (ROOT / "verif/v25" / f"run_v25_{stem}.sh").read_text(
                encoding="utf-8")
            self.assertIn(r"D:\vibes\fpga\toolchains\msys64", ps1)
            self.assertIn("R:\\Verilator\\", ps1)
            self.assertNotIn("& wsl", ps1)
            self.assertIn("$env:S32_V25_BUILD_ONLY = '1'", ps1)
            self.assertIn("& $safeSimulator -- $firmwareExe", ps1)
            self.assertIn("-CFLAGS -D_GLIBCXX_USE_CXX11_ABI=0", shell)
            self.assertIn("s32_verilator_workspace", shell)
            self.assertNotIn("scratch/tmp", shell.replace("\\", "/"))
            self.assertIn(f"{marker} EXE:", shell)
            self.assertIn(f"{marker} BUILD DIR:", shell)

    def test_sprite_srom_verification_uses_real_v25_descriptor_scope(self) -> None:
        core = (ROOT / "rtl/s32_core.sv").read_text(encoding="utf-8")
        self.assertIn(".VERIFY_SROM(1'b1)", core)
        self.assertIn(
            ".verify_srom(cfg_has_v25 && !cfg_v25_table)", core)
        self.assertNotIn(".verify_srom(!cfg_v25_table)", core)
        selected = {
            parent for parent, descriptor in GAMES.items()
            if (descriptor[0] & 0x02) and not (descriptor[0] & 0x04)
        }
        self.assertEqual(selected, {"ga2"})

    def test_rad_rally_gear_is_a_descriptor_selected_toggle(self) -> None:
        text = (ROOT / "Arcade-SegaSystem32.sv").read_text(encoding="utf-8")
        self.assertIn("if (joystick_0[6] && !radr_gear_btn_d)", text)
        self.assertIn("radr_gear <= ~radr_gear", text)
        self.assertIn("active_board.gear_toggle ? gear_toggle_p1a", text)

    def test_driving_pedals_use_right_stick_with_a_b_fallbacks(self) -> None:
        text = (ROOT / "Arcade-SegaSystem32.sv").read_text(encoding="utf-8")
        controls = (ROOT / "rtl/io/s32_driving_controls.sv").read_text(
            encoding="utf-8")
        self.assertIn(".joystick_r_analog_0(joystick_r_analog_0)", text)
        self.assertIn(".right_y(joystick_r_analog_0[15:8])", text)
        self.assertIn("stick_y < 0", controls)
        self.assertIn("stick_y > 0", controls)
        self.assertIn("digital_accel ? 8'hff", controls)
        self.assertIn("digital_brake ? 8'hff", controls)
        self.assertIn("active_board.gun_aim ? game_gun_p1_y : driving_accel", text)
        self.assertIn("active_board.gun_aim ? game_gun_p2_x : driving_brake", text)

    def test_rad_mobile_light_wiper_layout_is_descriptor_selected(self) -> None:
        text = (ROOT / "Arcade-SegaSystem32.sv").read_text(encoding="utf-8")
        self.assertIn("wire [7:0] radm_p1a", text)
        self.assertIn(
            "active_board.digital_profile == DIGITAL_RADM) ? radm_p1a",
            text,
        )

    def test_driving_wheel_has_no_stateful_intermediate_position(self) -> None:
        text = (ROOT / "Arcade-SegaSystem32.sv").read_text(encoding="utf-8")
        controls = (ROOT / "rtl/io/s32_driving_controls.sv").read_text(
            encoding="utf-8")
        self.assertIn(".left_x(joystick_l_analog_0[7:0])", text)
        self.assertIn(".right_y(joystick_r_analog_0[15:8])", text)
        self.assertIn("active_board.gun_aim ? game_gun_p1_x : driving_wheel", text)
        self.assertIn("wheel_pending_valid", controls)
        self.assertIn("wheel_sample", controls)
        self.assertIn("active_board.digital_profile == DIGITAL_RADM", text)
        self.assertIn(".adc0_load(adc0_load)", text)
        core = (ROOT / "rtl/s32_core.sv").read_text(encoding="utf-8")
        self.assertIn("assign adc0_load = wr_stb && sel_adc", core)
        self.assertIn("(A[2:1] == 2'd0)", core)
        for stale_state in ("wheel_sm", "wheel_div", "wheel_tick"):
            self.assertNotIn(stale_state, text)

    def test_standard_shape_retains_descriptor_gated_adc(self) -> None:
        text = (ROOT / "rtl/s32_core.sv").read_text(encoding="utf-8")
        self.assertIn("if (GAME_ONLY && !GAME_ONLY_STD) begin : g_no_adc", text)
        self.assertIn("s32_msm6253 adc (", text)
        self.assertIn(
            "wire sel_adc   = sel_ioex && (A[5:3] == 3'b010) && cfg_has_adc",
            text,
        )

    def test_standard_shape_excludes_removed_game_hardware(self) -> None:
        core = (ROOT / "rtl/s32_core.sv").read_text(encoding="utf-8")
        top = (ROOT / "Arcade-SegaSystem32.sv").read_text(encoding="utf-8")
        self.assertNotIn("s32_arescue_dsp dsp (", core)
        for removed in ("trackball",):
            self.assertNotIn(removed, (core + top).lower())
        self.assertIn("s32_prot_brival brival (", core)

    def test_attract_sweep_preserves_gate_and_capture_tail(self) -> None:
        """The matrix runner must request and finish every attract capture."""
        text = (ROOT / "verif/verilator/run_library_sweep.sh").read_text(
            encoding="utf-8")
        self.assertIn("run_args+=(+REQUIRE_VERILATOR_SCREENSHOT)", text)
        self.assertIn("slipstrm", text)
        self.assertNotIn("dbzvrvs", text)
        self.assertNotIn("sonic", text)
        self.assertIn("alien3 darkedge holo jpark radm", text)
        self.assertIn("spidman", text)
        self.assertIn("radm", text)


if __name__ == "__main__":
    unittest.main()
