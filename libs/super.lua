local function super(self, base)
	local metatable = getmetatable(self) or setmetatable(self, {})

	metatable.__classes = metatable.__classes or {}
	table.insert(metatable.__classes, 1, base)

	metatable.__name = base.__name
	metatable.__index = function(_, k)
		for _, class in ipairs(metatable.__classes) do
			if class[k] then
				return class[k]
			end
		end
	end
end

return super