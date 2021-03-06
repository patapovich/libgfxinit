--
-- Copyright (C) 2014-2016 secunet Security Networks AG
--
-- This program is free software; you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation; either version 2 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--

with HW.GFX.GMA.Config;
with HW.GFX.GMA.Config_Helpers;
with HW.GFX.GMA.Registers;
with HW.GFX.GMA.Power_And_Clocks;
with HW.GFX.GMA.Panel;
with HW.GFX.GMA.PLLs;
with HW.GFX.GMA.Port_Detect;
with HW.GFX.GMA.Connectors;
with HW.GFX.GMA.Connector_Info;
with HW.GFX.GMA.Pipe_Setup;

with System;

with HW.Debug;
with GNAT.Source_Info;

use type HW.Word8;
use type HW.Int32;

package body HW.GFX.GMA
   with Refined_State =>
     (State =>
        (Registers.Address_State,
         PLLs.State, Panel.Panel_State,
         Cur_Configs, Allocated_PLLs, DP_Links,
         HPD_Delay, Wait_For_HPD),
      Init_State => Initialized,
      Config_State => Config.Valid_Port_GPU,
      Device_State =>
        (Registers.Register_State, Registers.GTT_State))
is

   subtype Port_Name is String (1 .. 8);
   type Port_Name_Array is array (Port_Type) of Port_Name;
   Port_Names : constant Port_Name_Array :=
     (Disabled => "Disabled",
      Internal => "Internal",
      DP1      => "DP1     ",
      DP2      => "DP2     ",
      DP3      => "DP3     ",
      HDMI1    => "HDMI1   ",
      HDMI2    => "HDMI2   ",
      HDMI3    => "HDMI3   ",
      Analog   => "Analog  ");

   package Display_Controller renames Pipe_Setup;

   type PLLs_Type is array (Pipe_Index) of PLLs.T;

   type Links_Type is array (Pipe_Index) of DP_Link;

   type HPD_Type is array (Port_Type) of Boolean;
   type HPD_Delay_Type is array (Port_Type) of Time.T;

   Allocated_PLLs : PLLs_Type;
   DP_Links : Links_Type;
   HPD_Delay : HPD_Delay_Type;
   Wait_For_HPD : HPD_Type;
   Initialized : Boolean := False;

   ----------------------------------------------------------------------------

   PCH_RAWCLK_FREQ_MASK                : constant := 16#3ff# * 2 ** 0;

   function PCH_RAWCLK_FREQ (Freq : Frequency_Type) return Word32
   is
   begin
      return Word32 (Freq / 1_000_000);
   end PCH_RAWCLK_FREQ;

   ----------------------------------------------------------------------------

   function To_Controller
      (Dsp_Config : Pipe_Index) return Display_Controller.Controller_Type
   is
      Result : Display_Controller.Controller_Type;
   begin
      pragma Debug (Debug.Put_Line (GNAT.Source_Info.Enclosing_Entity));

      case Dsp_Config is
         when Primary =>
            Result := Display_Controller.Controllers (Display_Controller.A);
         when Secondary =>
            Result := Display_Controller.Controllers (Display_Controller.B);
         when Tertiary =>
            Result := Display_Controller.Controllers (Display_Controller.C);
      end case;
      return Result;
   end To_Controller;

   ----------------------------------------------------------------------------

   function To_Head
     (N_Config : Pipe_Index;
      Port     : Active_Port_Type)
      return Display_Controller.Head_Type
   is
      Result : Display_Controller.Head_Type;
   begin
      pragma Debug (Debug.Put_Line (GNAT.Source_Info.Enclosing_Entity));

      if Config.Has_EDP_Pipe and then Port = Internal then
         Result := Display_Controller.Heads (Display_Controller.Head_EDP);
      else
         case N_Config is
            when Primary =>
               Result := Display_Controller.Heads (Display_Controller.Head_A);
            when Secondary =>
               Result := Display_Controller.Heads (Display_Controller.Head_B);
            when Tertiary =>
               Result := Display_Controller.Heads (Display_Controller.Head_C);
         end case;
      end if;
      return Result;
   end To_Head;

   ----------------------------------------------------------------------------

   procedure Legacy_VGA_Off
   is
      Reg8 : Word8;
   begin
      -- disable legacy VGA plane, taking over control now
      Port_IO.OutB (VGA_SR_INDEX, VGA_SR01);
      Port_IO.InB  (Reg8, VGA_SR_DATA);
      Port_IO.OutB (VGA_SR_DATA, Reg8 or 1 * 2 ** 5);
      Time.U_Delay (100); -- PRM says 100us, Linux does 300
      Registers.Set_Mask (Registers.VGACNTRL, 1 * 2 ** 31);
   end Legacy_VGA_Off;

   ----------------------------------------------------------------------------

   procedure Update_Outputs (Configs : Pipe_Configs)
   is
      Did_Power_Up : Boolean := False;

      HPD, HPD_Delay_Over, Success : Boolean;
      Old_Config, New_Config : Pipe_Config;
      Old_Configs : Pipe_Configs;
      Port_Cfg : Port_Config;

      procedure Check_HPD
        (Port_Cfg : in     Port_Config;
         Port     : in     Port_Type;
         Detected :    out Boolean)
      is
      begin
         HPD_Delay_Over := Time.Timed_Out (HPD_Delay (Port));
         if HPD_Delay_Over then
            Port_Detect.Hotplug_Detect (Port_Cfg, Detected);
            HPD_Delay (Port) := Time.MS_From_Now (333);
         else
            Detected := False;
         end if;
      end Check_HPD;
   begin
      Old_Configs := Cur_Configs;

      for I in Pipe_Index loop
         HPD := False;

         Old_Config := Cur_Configs (I);
         New_Config := Configs (I);

         Config_Helpers.Fill_Port_Config
           (Port_Cfg, I, Old_Configs (I).Port, Old_Configs (I).Mode, Success);
         Port_Cfg.DP := DP_Links (I);
         if Success then
            Check_HPD (Port_Cfg, Old_Config.Port, HPD);
         end if;

         -- Connector changed?
         if (Success and then HPD) or
            Old_Config.Port /= New_Config.Port or
            Old_Config.Mode /= New_Config.Mode
         then
            if Old_Config.Port /= Disabled then
               if Success then
                  pragma Debug (Debug.New_Line);
                  pragma Debug (Debug.Put_Line
                    ("Disabling port " & Port_Names (Old_Config.Port)));

                  Connectors.Pre_Off (Port_Cfg);

                  Display_Controller.Off
                    (To_Controller (I), To_Head (I, Old_Config.Port));

                  Connectors.Post_Off (Port_Cfg);
               end if;

               -- Free PLL
               PLLs.Free (Allocated_PLLs (I));

               Cur_Configs (I).Port := Disabled;
            end if;

            if New_Config.Port /= Disabled then
               Config_Helpers.Fill_Port_Config
                 (Port_Cfg, I, Configs (I).Port, Configs (I).Mode, Success);

               if Success then
                  Success := Config_Helpers.Validate_Config
                    (New_Config.Framebuffer, Port_Cfg, I);
               end if;

               if Success and then Wait_For_HPD (New_Config.Port) then
                  Check_HPD (Port_Cfg, New_Config.Port, Success);
                  Wait_For_HPD (New_Config.Port) := not Success;
               end if;

               if Success then
                  pragma Debug (Debug.New_Line);
                  pragma Debug (Debug.Put_Line
                    ("Trying to enable port " & Port_Names (New_Config.Port)));

                  if not Did_Power_Up then
                     Power_And_Clocks.Power_Up (Old_Configs, Configs);
                     Did_Power_Up := True;
                  end if;
               end if;

               if Success then
                  Connector_Info.Preferred_Link_Setting
                    (Port_Cfg => Port_Cfg,
                     Success  => Success);
               end if;

               while Success loop
                  pragma Loop_Invariant
                    (New_Config.Port in Active_Port_Type and
                     Port_Cfg.Mode = Port_Cfg.Mode'Loop_Entry);

                  PLLs.Alloc
                    (Port_Cfg => Port_Cfg,
                     PLL      => Allocated_PLLs (I),
                     Success  => Success);

                  if Success then
                     for Try in 1 .. 2 loop
                        pragma Loop_Invariant
                          (New_Config.Port in Active_Port_Type);

                        Connectors.Pre_On
                          (Port_Cfg    => Port_Cfg,
                           PLL_Hint    => PLLs.Register_Value
                                            (Allocated_PLLs (I)),
                           Pipe_Hint   => Display_Controller.Get_Pipe_Hint
                                            (To_Head (I, New_Config.Port)),
                           Success     => Success);

                        if Success then
                           Display_Controller.On
                             (Controller  => To_Controller (I),
                              Head        => To_Head (I, New_Config.Port),
                              Port_Cfg    => Port_Cfg,
                              Framebuffer => New_Config.Framebuffer);

                           Connectors.Post_On
                             (Port_Cfg => Port_Cfg,
                              PLL_Hint => PLLs.Register_Value
                                            (Allocated_PLLs (I)),
                              Success  => Success);

                           if not Success then
                              Display_Controller.Off
                                (To_Controller (I),
                                 To_Head (I, New_Config.Port));
                              Connectors.Post_Off (Port_Cfg);
                           end if;
                        end if;

                        exit when Success;
                     end loop;
                     exit when Success;   -- connection established => stop loop

                     -- connection failed
                     PLLs.Free (Allocated_PLLs (I));
                  end if;

                  Connector_Info.Next_Link_Setting
                    (Port_Cfg => Port_Cfg,
                     Success  => Success);
               end loop;

               if Success then
                  pragma Debug (Debug.Put_Line
                    ("Enabled port " & Port_Names (New_Config.Port)));
                  Cur_Configs (I) := New_Config;
                  DP_Links (I) := Port_Cfg.DP;
               else
                  Wait_For_HPD (New_Config.Port) := True;
                  if New_Config.Port = Internal then
                     Panel.Off;
                  end if;
               end if;
            else
               Cur_Configs (I) := New_Config;
            end if;
         elsif Old_Config.Framebuffer /= New_Config.Framebuffer and
               Old_Config.Port /= Disabled
         then
            Display_Controller.Update_Offset
              (Controller  => To_Controller (I),
               Framebuffer => New_Config.Framebuffer);
            Cur_Configs (I) := New_Config;
         end if;
      end loop;

      if Did_Power_Up then
         Power_And_Clocks.Power_Down (Old_Configs, Configs, Cur_Configs);
      end if;

   end Update_Outputs;

   ----------------------------------------------------------------------------

   procedure Initialize
     (MMIO_Base   : in     Word64 := 0;
      Write_Delay : in     Word64 := 0;
      Clean_State : in     Boolean := False;
      Success     :    out Boolean)
   with
      Refined_Global =>
        (In_Out =>
           (Config.Valid_Port_GPU,
            Registers.Register_State, Port_IO.State),
         Input =>
           (Time.State),
         Output =>
           (Registers.Address_State,
            PLLs.State, Panel.Panel_State,
            Cur_Configs, Allocated_PLLs, DP_Links,
            HPD_Delay, Wait_For_HPD, Initialized))
   is
      use type HW.Word64;

      Now : constant Time.T := Time.Now;

      procedure Check_Platform (Success : out Boolean)
      is
         Audio_VID_DID : Word32;
      begin
         case Config.CPU is
            when Haswell .. Skylake =>
               Registers.Read (Registers.AUD_VID_DID, Audio_VID_DID);
            when Ironlake .. Ivybridge =>
               Registers.Read (Registers.PCH_AUD_VID_DID, Audio_VID_DID);
         end case;
         Success :=
           (case Config.CPU is
               when Skylake      => Audio_VID_DID = 16#8086_2809#,
               when Broadwell    => Audio_VID_DID = 16#8086_2808#,
               when Haswell      => Audio_VID_DID = 16#8086_2807#,
               when Ivybridge |
                    Sandybridge  => Audio_VID_DID = 16#8086_2806# or
                                    Audio_VID_DID = 16#8086_2805#,
               when Ironlake     => Audio_VID_DID = 16#0000_0000#);
      end Check_Platform;
   begin
      pragma Warnings (GNATprove, Off, "unused variable ""Write_Delay""",
         Reason => "Write_Delay is used for debugging only");

      pragma Debug (Debug.Put_Line (GNAT.Source_Info.Enclosing_Entity));

      pragma Debug (Debug.Set_Register_Write_Delay (Write_Delay));

      Wait_For_HPD := HPD_Type'(others => False);
      HPD_Delay := HPD_Delay_Type'(others => Now);
      DP_Links := Links_Type'(others => HW.GFX.Default_DP);
      Allocated_PLLs := (others => PLLs.Invalid);
      Cur_Configs := Pipe_Configs'
        (others => Pipe_Config'
           (Port        => Disabled,
            Framebuffer => HW.GFX.Default_FB,
            Mode        => HW.GFX.Invalid_Mode));
      Registers.Set_Register_Base
        (if MMIO_Base /= 0 then
            MMIO_Base
         else
            Config.Default_MMIO_Base);
      PLLs.Initialize;

      Check_Platform (Success);
      if not Success then
         pragma Debug (Debug.Put_Line ("ERROR: Incompatible CPU or PCH."));

         Panel.Static_Init;   -- for flow analysis

         Initialized := False;
         return;
      end if;

      Panel.Setup_PP_Sequencer;
      Port_Detect.Initialize;

      Legacy_VGA_Off;   -- According to PRMs, VGA plane is the only
                        -- thing that's enabled by default after reset.

      if Clean_State then
         Power_And_Clocks.Pre_All_Off;
         Connectors.Pre_All_Off;
         Display_Controller.All_Off;
         Connectors.Post_All_Off;
         PLLs.All_Off;
         Power_And_Clocks.Post_All_Off;
      end if;

      -------------------- Now restart from a clean state ---------------------
      Power_And_Clocks.Initialize;

      Registers.Unset_And_Set_Mask
        (Register    => Registers.PCH_RAWCLK_FREQ,
         Mask_Unset  => PCH_RAWCLK_FREQ_MASK,
         Mask_Set    => PCH_RAWCLK_FREQ (Config.Default_RawClk_Freq));

      Initialized := True;

   end Initialize;

   function Is_Initialized return Boolean
   with
      Refined_Post => Is_Initialized'Result = Initialized
   is
   begin
      return Initialized;
   end Is_Initialized;

   ----------------------------------------------------------------------------

   procedure Write_GTT
     (GTT_Page       : GTT_Range;
      Device_Address : GTT_Address_Type;
      Valid          : Boolean) is
   begin
      Registers.Write_GTT (GTT_Page, Device_Address, Valid);
   end Write_GTT;

   procedure Setup_Default_GTT (FB : Framebuffer_Type; Phys_FB : Word32)
   is
      FB_Size : constant Pos32 :=
         FB.Stride * FB.Height * Pos32 (((FB.BPC * 4) / 8));
      Phys_Addr : GTT_Address_Type := GTT_Address_Type (Phys_FB);
   begin
      for Idx in GTT_Range range 0 .. GTT_Range (((FB_Size + 4095) / 4096) - 1)
      loop
         Registers.Write_GTT
           (GTT_Page       => Idx,
            Device_Address => Phys_Addr,
            Valid          => True);
         Phys_Addr := Phys_Addr + 4096;
      end loop;
   end Setup_Default_GTT;

   ----------------------------------------------------------------------------

   procedure Dump_Configs (Configs : Pipe_Configs)
   is
      subtype Pipe_Name is String (1 .. 9);
      type Pipe_Name_Array is array (Pipe_Index) of Pipe_Name;
      Pipe_Names : constant Pipe_Name_Array :=
        (Primary     => "Primary  ",
         Secondary   => "Secondary",
         Tertiary    => "Tertiary ");
   begin
      Debug.New_Line;
      Debug.Put_Line ("CONFIG => ");
      for Pipe in Pipe_Index loop
         if Pipe = Pipe_Index'First then
            Debug.Put ("  (");
         else
            Debug.Put ("   ");
         end if;
         Debug.Put_Line (Pipe_Names (Pipe) & " =>");
         Debug.Put_Line
           ("     (Port => " & Port_Names (Configs (Pipe).Port) & ",");
         Debug.Put_Line ("      Framebuffer =>");
         Debug.Put ("        (Width  => ");
         Debug.Put_Int32 (Configs (Pipe).Framebuffer.Width);
         Debug.Put_Line (",");
         Debug.Put ("         Height => ");
         Debug.Put_Int32 (Configs (Pipe).Framebuffer.Height);
         Debug.Put_Line (",");
         Debug.Put ("         Stride => ");
         Debug.Put_Int32 (Configs (Pipe).Framebuffer.Stride);
         Debug.Put_Line (",");
         Debug.Put ("         Offset => ");
         Debug.Put_Word32 (Configs (Pipe).Framebuffer.Offset);
         Debug.Put_Line (",");
         Debug.Put ("         BPC    => ");
         Debug.Put_Int64 (Configs (Pipe).Framebuffer.BPC);
         Debug.Put_Line ("),");
         Debug.Put_Line ("      Mode =>");
         Debug.Put ("        (Dotclock           => ");
         Debug.Put_Int64 (Configs (Pipe).Mode.Dotclock);
         Debug.Put_Line (",");
         Debug.Put ("         H_Visible          => ");
         Debug.Put_Int16 (Configs (Pipe).Mode.H_Visible);
         Debug.Put_Line (",");
         Debug.Put ("         H_Sync_Begin       => ");
         Debug.Put_Int16 (Configs (Pipe).Mode.H_Sync_Begin);
         Debug.Put_Line (",");
         Debug.Put ("         H_Sync_End         => ");
         Debug.Put_Int16 (Configs (Pipe).Mode.H_Sync_End);
         Debug.Put_Line (",");
         Debug.Put ("         H_Total            => ");
         Debug.Put_Int16 (Configs (Pipe).Mode.H_Total);
         Debug.Put_Line (",");
         Debug.Put ("         V_Visible          => ");
         Debug.Put_Int16 (Configs (Pipe).Mode.V_Visible);
         Debug.Put_Line (",");
         Debug.Put ("         V_Sync_Begin       => ");
         Debug.Put_Int16 (Configs (Pipe).Mode.V_Sync_Begin);
         Debug.Put_Line (",");
         Debug.Put ("         V_Sync_End         => ");
         Debug.Put_Int16 (Configs (Pipe).Mode.V_Sync_End);
         Debug.Put_Line (",");
         Debug.Put ("         V_Total            => ");
         Debug.Put_Int16 (Configs (Pipe).Mode.V_Total);
         Debug.Put_Line (",");
         Debug.Put_Line ("         H_Sync_Active_High => " &
           (if Configs (Pipe).Mode.H_Sync_Active_High
            then "True,"
            else "False,"));
         Debug.Put_Line ("         V_Sync_Active_High => " &
           (if Configs (Pipe).Mode.V_Sync_Active_High
            then "True,"
            else "False,"));
         Debug.Put ("         BPC                => ");
         Debug.Put_Int64 (Configs (Pipe).Mode.BPC);
         if Pipe /= Pipe_Index'Last then
            Debug.Put_Line (")),");
         else
            Debug.Put_Line (")));");
         end if;
      end loop;
   end Dump_Configs;

end HW.GFX.GMA;
