--[[
Written by:	Tony Fernandez

Date:		May 5th 2021

Purpose:	This script will look in the postgres database and dial out to a phone
			number and play a wav file. It will also ask for an acknowledgement
			of receiving the message. All this will be stored in the database.

Database table name: v_dialer_service

Database table columns:
	primary_key (serial):	used to uniquly identify each row. This is set to auto increment
	-------------------------------------------------------------------------------------------------
	campaign_name: 			used to differenciate each calling campaign. This is used
							as the Caller ID Name.
	-------------------------------------------------------------------------------------------------
	identifier:				used to differenciate between calls in the campaign
	-------------------------------------------------------------------------------------------------
	phone_number:			the phone number that the system will dial
	-------------------------------------------------------------------------------------------------
	wav_location:			the absolute path to the wav file that needs to be played
	-------------------------------------------------------------------------------------------------
	status:					current status of the call. Currently there are two.

							waiting - 	this status is used to show calls that are waiting
										to be (re)attempted
							complete - 	this status is used when a call either is accepted
										or has hit the max attempts
	-------------------------------------------------------------------------------------------------
	result:					the result of the last attempt. This can be a success or failure
							accepted  - 	When a user pressed a digit to accept
							USER_BUSY -	SIP 486 - For BUSY you may reschedule the call for later
							NO_ANSWER -	System received no answer
							ORIGINATOR_CANCEL - May need to check for network congestion or problems
--]]



--connect to the database
	Database = require "resources.functions.database";
	dbh = Database.new('system');

--debug
	debug["info"] = true;
	debug["sql"] = true;

-- get waiting calls
	sql = [[SELECT * FROM v_dialer_queue vdq WHERE vdq.status = 'waiting' AND vdq.attempts < 3 LIMIT 1]];

--general vars
	values_returned = 0 -- var to see if there is any values in the query
	max_attempts = 3 -- max call attempts
	dispoA = "None" --default disposition
	transfer_dest = "sofia/internal/102%lab.smartipcloud.com" --destination for the calls to be transfered to in selected.


-- build array from sql query
	queue = {} --used for storing calls in queue
	dbh:query(sql, params, function(result)
		values_returned = 1
		for key, val in pairs(result) do
			queue[key] = val
			if (debug["sql"]) then
				freeswitch.consoleLog("notice", "Calls in queue: " .. key.. ": " .. val .. "\n");
			end
		end
	end);
	-- dbh:release();
	--check if there are calls in the table
	if values_returned == 1 then
		freeswitch.consoleLog("notice", "Attempting to call out." .. "\n");
		
		--attempt the call
		outSession = freeswitch.Session("{origination_caller_id_name="..queue["campaign_name"]..",origination_caller_id_number=".. "9057592660" .."}sofia/gateway/20ce1603-7865-46c3-86dc-a06f4f1b43b8/".. queue["phone_number"])
		outSession:setAutoHangup(false)

		while(outSession:ready() and dispoA ~= "ANSWER") do
			dispoA = outSession:getVariable("endpoint_disposition")
			freeswitch.consoleLog("INFO","Leg A disposition is '" .. dispoA .. "'\n")
			os.execute("sleep 1")
		end
		if ( outSession:ready() ) then
			--pause for 1 second
				outSession:execute("sleep", 1000)

			--play and collect digits (min_digits,max_digits,max_attempts,timeout,terminators,audio_file,error_audio_file,digit_regex)
				digits = outSession:playAndGetDigits(1, 1, 3, 5000, "", queue["wav_location"], "/error.wav", "\\d+")

			-- if 1 is pressed then the call is accepted
			if digits == "1" then
				outSession:consoleLog("info", "Message to ".. queue["phone_number"] .." accepted" .."\n")
				local params = {
					primary_key = queue["primary_key"];
				}
				dbh:query("UPDATE v_dialer_queue SET status = 'complete', result = 'accepted', attempts = "..queue["attempts"]+1 .." where primary_key = :primary_key", params);
				digits = outSession:playAndGetDigits(1, 1, 3, 5000, "", "/var/lib/freeswitch/recordings/lab.smartipcloud.com/recording3.wav", "/error.wav", "\\d+")
				if digits == "1" then
					legB = freeswitch.Session(transfer_dest)
					if ( outSession:ready() and legB:ready() ) then
        				freeswitch.bridge(outSession,legB)
    				end
				end
			else
				--caller did not press 1 - add an attempt
				local params = {
					primary_key = queue["primary_key"];
				}
				dbh:query("UPDATE v_dialer_queue SET result = 'not_accepted', attempts = "..queue["attempts"]+1 .." where primary_key = :primary_key", params);
			end
			outSession:hangup();

		--unable to complete the call
		else
			-- opps, lost leg A handle this case
			freeswitch.consoleLog("NOTICE","It appears that outSession is disconnected...\n")


			-- log the hangup cause
			local outCause = outSession:hangupCause()
			freeswitch.consoleLog("info", "outSession:hangupCause() = " .. outCause)

		    if ( outCause == "USER_BUSY" ) then				-- SIP 486 -- For BUSY you may reschedule the call for later

		    elseif ( outCause == "NO_ANSWER" ) then 		-- Call them back in an hour

		    elseif ( outCause == "ORIGINATOR_CANCEL" ) then	-- SIP 487 -- May need to check for network congestion or problems

		    else  --unknown cause
		       freeswitch.consoleLog("info", "Unknown outSession:hangupCause() = " .. outCause)
		    end

		    -- we've hit max attempts
		    if queue["attempts"]+1 == max_attempts then
		    	status = "complete"
		    	freeswitch.consoleLog("warn", "Maximum attempts ("..max_attempts..") hit for: " .. queue["phone_number"])
		    else
		    	status = "waiting"
		    	freeswitch.consoleLog("warn", "Current attempts for: " .. queue["phone_number"] .. " is "..queue["attempts"])
		    end
			local params = {
				primary_key = queue["primary_key"];
			}
			dbh:query("UPDATE v_dialer_queue SET status = '".. status .."', attempts = ".. queue["attempts"]+1 ..", result = '".. outCause .."' where primary_key = :primary_key", params);

		end
	else
		freeswitch.consoleLog("notice", "No calls need to be dialed." .. "\n");
	end
	dbh:release();
