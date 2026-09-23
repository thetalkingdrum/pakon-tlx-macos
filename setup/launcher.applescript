-- Pakon Scanner: double-click launcher for pakon-tlx-macos.
-- Runs ./run.sh with no Terminal, reports problems in dialogs, and stops the
-- USB server once the TLX client window is closed.
--
-- Built by `./run.sh make-app`, which records the repo's location in the
-- bundle's Contents/Resources/repo-path.  Re-run it if the repo moves.

global repo

on sh(cmd)
	-- Apps get a bare PATH; run.sh needs Homebrew's (brew --prefix libusb, wine).
	return do shell script "export PATH=/usr/local/bin:/opt/homebrew/bin:$PATH; cd " & quoted form of repo & " && " & cmd
end sh

on logFile()
	return (POSIX path of (path to library folder from user domain)) & "Logs/Pakon Scanner.log"
end logFile

on clientRunning()
	-- The [.] keeps pgrep from matching the sh -c that runs it.
	try
		sh("pgrep -f 'TLXClientDemo[.]exe' >/dev/null")
		return true
	on error
		return false
	end try
end clientRunning

on findRepo()
	set f to (POSIX path of (path to me)) & "Contents/Resources/repo-path"
	try
		set repo to do shell script "cat " & quoted form of f
		do shell script "test -x " & quoted form of (repo & "/run.sh")
		return true
	on error
		display dialog "Can't find the pakon-tlx-macos folder" & (" at:" & return & repo) & return & return & "If you moved it, rebuild this app from the new location with:" & return & "./run.sh make-app" buttons {"Quit"} default button 1 with title "Pakon Scanner" with icon stop
		return false
	end try
end findRepo

on run
	if not findRepo() then
		quit
		return
	end if
	if clientRunning() then
		display dialog "The Pakon client is already running." & return & return & "Bring it forward from the Dock." buttons {"OK"} default button 1 with title "Pakon Scanner" with icon note
		return
	end if
	repeat
		-- Output goes to a file: run.sh leaves a background subshell holding
		-- its stdout, so waiting on a pipe would never return.
		set lf to logFile()
		set rc to sh("./run.sh > " & quoted form of lf & " 2>&1 < /dev/null; echo $?") as integer
		if rc is 0 then
			display notification "Scanner ready. The client window is opening." with title "Pakon Scanner"
			return
		end if
		set out to do shell script "tail -12 " & quoted form of lf
		if out contains "No scanner on the USB bus" then
			set msg to "No scanner found." & return & return & "Switch the Pakon on and check the USB cable, then press Try Again."
		else if out contains "still starting" then
			-- Firmware upload + re-enumeration outran run.sh's wait: just retry.
			delay 3
			set msg to ""
		else
			set msg to "The scanner could not be started:" & return & return & out
		end if
		if msg is not "" then
			set b to button returned of (display dialog msg buttons {"Quit", "Show Log", "Try Again"} default button "Try Again" with title "Pakon Scanner" with icon caution)
			if b is "Quit" then
				quit
				return
			else if b is "Show Log" then
				do shell script "open -a Console " & quoted form of lf
				quit
				return
			end if
		end if
	end repeat
end run

on idle
	if clientRunning() then return 5
	-- Client closed: take the USB server down with it.
	try
		sh("./run.sh stop >/dev/null 2>&1")
	end try
	display notification "Scanner stopped." with title "Pakon Scanner"
	quit
	return 5
end idle

on quit
	if clientRunning() then
		set b to button returned of (display dialog "The Pakon client is still open. Close it and stop the scanner?" buttons {"Keep Running", "Stop"} default button "Keep Running" with title "Pakon Scanner" with icon caution)
		if b is "Keep Running" then return
		try
			sh("./run.sh stop >/dev/null 2>&1")
		end try
	end if
	continue quit
end quit
