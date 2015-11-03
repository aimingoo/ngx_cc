-----------------------------------------------------------------------------
-- Valider class v1.1.1
-- Author: aimingoo@wandoujia.com
-- Copyright (c) 2015.06
--
-- The promise module from NGX_4C architecture
--	1) N4C is programming framework.
--	2) N4C = a Controllable & Computable Communication Cluster architectur.
--
-- Usage:
--	checker = require('Valider'):new(opt)
--	isInvalid = checker:invalid(key, isContinuous)
--
-- History:
--	2015.10.29	release v1.1.1, update testcases
--	2015.08.12	release v1.1, rewirte invalid() without queue, publish on github
--	2015.08.11	release v1.0.1, full testcases
--	2015.03		release v1.0.0
-----------------------------------------------------------------------------

local Valider = {
	maxContinuousInterval = 3,
	maxContinuous = 100,	-- continuous invalid X times (default 100), or
	maxTimes = 30,			-- invalid X times in Y seconds history (default is 30 times in 30s)
	maxSeconds = 30			-- (max history seconds, default is 30s)
}

function Valider:invalid(key, isContinuous)  -- key is '<channel>.<addr>' or anythings
	if not rawget(self, key) then
		rawset(self, key, { 1, 0, os.time(), 0 }) -- { count, seconds, lastTime, continuous }
	else
		local now, s = os.time(), rawget(self, key)
		local count, seconds, lastTime, continuous = s[1], s[2], s[3], s[4]  -- or unpack(s)
		s[3], s[4] = now, (isContinuous or (lastTime+self.maxContinuousInterval) > now) and continuous + 1 or 0

		local gapTime, maxSeconds = now - lastTime, self.maxSeconds
		if gapTime > maxSeconds then -- reset
			s[1], s[2] = 1, 0
			return false
		end

		local saveTime = seconds + gapTime
		local dropTime = saveTime - maxSeconds
		if dropTime > 0 then
			local avgTime = seconds/count
			local dropN = math.ceil(dropTime/avgTime)
			s[1], s[2] = count - dropN + 1, math.ceil(seconds - dropN*avgTime)
		else
			s[1], s[2] = count + 1, saveTime
		end

		return ((s[4] >= self.maxContinuous) or
				(s[1] >= self.maxTimes))
	end
end

function Valider:new(opt)  -- options or nil
	return setmetatable({}, {  -- instance is empty on init
		__index = opt and setmetatable(opt, {__index=self}) or self -- access options
	})
end

return Valider