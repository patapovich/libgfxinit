--
-- Copyright (C) 2015-2016 secunet Security Networks AG
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

with HW;

private package HW.GFX.GMA.Config_Helpers
is

   function To_PCH_Port (Port : Active_Port_Type) return PCH_Port;

   function To_Display_Type (Port : Active_Port_Type) return Display_Type;

   procedure Fill_Port_Config
     (Port_Cfg :    out Port_Config;
      Pipe     : in     Pipe_Index;
      Port     : in     Port_Type;
      Mode     : in     Mode_Type;
      Success  :    out Boolean);

   ----------------------------------------------------------------------------

   use type HW.Pos32;
   function Validate_Config
     (Framebuffer : Framebuffer_Type;
      Port_Cfg    : Port_Config;
      Pipe        : Pipe_Index)
      return Boolean
   with
      Post =>
        (if Validate_Config'Result then
            Framebuffer.Width <= Pos32 (Port_Cfg.Mode.H_Visible) and
            Framebuffer.Height <= Pos32 (Port_Cfg.Mode.V_Visible));

end HW.GFX.GMA.Config_Helpers;
