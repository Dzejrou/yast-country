# Copyright (c) [2019] SUSE LLC
#
# All Rights Reserved.
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of version 2 of the GNU General Public License as published
# by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
# more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, contact SUSE LLC.
#
# To contact SUSE LLC about this file by physical or electronic mail, you may
# find current contact information at www.suse.com.

require "yast"
require "yast2/execute"
require "shellwords"

module Y2Keyboard
  module Strategies
    Yast.import "Directory"
    Yast.import "Stage"

    # Class to deal with xkb and kbd keyboard configuration management.
    # Use this class only for temporary changes like changing keyboard
    # layout "on the fly" for example in the inst-sys.
    #
    # Use the systemd strategy for making keyboard changes permanent on
    # the installed system.
    #
    class KbStrategy
      include Yast::Logger

      # Writing rules in /etc/udev would result in those files being copied to
      # the installed system. That's not what we want. sys-int is temporary, so
      # writing in its /run is safe.
      UDEV_FILE = "/run/udev/rules.d/70-installation-keyboard.rules"
      UDEV_COMMENT = "# Generated by Yast to handle the layout of keyboards "\
                     "connected during installation\n"

      # Used to set keybaord layout in a running system.
      # @param keyboard_code [String] the keyboard layout (e.g. "us") to set
      # in the running the system (mostly temporary).
      def set_layout(keyboard_code)
        if keyboard_code.nil? || keyboard_code.empty?
          log.info "Keyboard has not been defined. Do not set it."
          return
        end

        if Yast::UI.TextMode
          begin
            Yast::Execute.on_target!("loadkeys", *loadkeys_devices("tty"), keyboard_code)
            # It could be that for seriell tty's the keyboard cannot be set. So it will
            # be done separately in order to ensure that setting console keyboard
            # will be done successfully in the previous call.
            Yast::Execute.on_target!("loadkeys", *loadkeys_devices("ttyS"), keyboard_code)
          rescue Cheetah::ExecutionFailed => e
            log.info(e.message)
            log.info("Error output:    #{e.stderr}")
          end
        else
          # X11 mode
          set_x11_layout(keyboard_code)
        end
      end

    private

    # set x11 keys on the fly.
    # @param keyboard_code [String] the keyboard to set.
    def set_x11_layout(keyboard_code)
        x11data = get_x11_data(keyboard_code)
        return if x11data.empty?

        Kernel.system("/usr/bin/setxkbmap " + x11data["Apply"])

        # bnc#885271: set udev rule to handle incoming attached keyboards
        # While installation/update only.
        write_udev_rule(x11data) if Yast::Stage.initial
      end

      # String to specify all the relevant devices in a loadkeys command
      #
      # It includes all tty[0-9]* and ttyS[0-9]* devices (bsc#1010938).
      #
      # @param [String] kind of tty ("tty", "ttyS")
      # @return [Array<String>] array with params for the loadkeys command
      def loadkeys_devices(kind)
        tty_dev_names = Dir["/dev/#{kind}[0-9]*"]
        tty_dev_names.each_with_object([]) { |d,res| res << "-C" << d }
      end

      # GetX11KeyData()
      #
      # Get the keyboard info for X11 for the given keymap
      #
      # @param	name of the keymap
      #
      # @return  [Hash] containing the x11 config data
      #
      def get_x11_data(keymap)
        cmd = "/usr/sbin/xkbctrl"
        x11data = {}

        if File.executable?(cmd)
          file = File.join(Yast::Directory.tmpdir, "xkbctrl.out")
          Kernel.system("#{cmd} #{keymap.shellescape} >#{file}")
          x11data = Yast::SCR.Read(Yast::path(".target.ycp"), file)
        else
          log.warn("#{cmd} not found on system.")
        end
        x11data
      end

      # Creates an udev rule to manage the layout for keyboards that are
      # hotplugged during the installation process
      #
      # @param	[Hash] X11 settings

      def write_udev_rule(x11data)
        # Remove the file if present (needed to make udev aware of changes)
        File.delete(UDEV_FILE) if File.file?(UDEV_FILE)

        # Using an array of arrays instead of a hash to get a predictable and
        # ordered rule (even if it's not required by udev itself)
        udev_env = [["XKBLAYOUT", x11data["XkbLayout"] || ""],
                    ["XKBMODEL", x11data["XkbModel"] || ""],
                    ["XKBOPTIONS", x11data["XkbOptions"] || ""]]
        udev_env.delete_if {|key,value| value.nil? || value.empty? }
        if !udev_env.empty?
          rule = 'ENV{ID_INPUT_KEYBOARD}=="1", '
          rule << udev_env.map {|key,value| "ENV{#{key}}=\"#{value}\"" }.join(", ")
          Yast::SCR.Write(Yast::path(".target.string"), UDEV_FILE, UDEV_COMMENT + rule + "\n")
          Yast::SCR.Write(Yast::path(".target.string"), UDEV_FILE, nil)
        end
      end

    end
  end
end
