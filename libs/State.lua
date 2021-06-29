local State = {}
State.__name = 'State'
State.__index = State

function State.new(config)
	local self = setmetatable({}, State)

	self.class_map = {}
	self.class_list = {}
	self.enumerations = {}
	self.config = config or {}

	self.prepared = nil
end

function State:newClass(class)
	self.class_map[class.name] = class
	self.class_list[#self.class_list + 1] = class
end

function State:addEnumerations(enums)
	for enum, tbl in pairs(enums) do
		self.enumerations[enum] = self.enumerations[enum] or {}
		for name, value in pairs(tbl) do
			self.enumerations[enum][name] = value
		end
	end
end

function State:prepareNavigation()
	local hierarchy = {}
	local tlc = {}

	for _, class in ipairs(self.class_list) do
		if #class.inherits == 0 then
			table.insert(tlc, class.name)
		else
			for _, parent in ipairs(class.inherits) do
				hierarchy[parent] = hierarchy[parent] or {}
				table.insert(hierarchy[parent], class.name)
				table.sort(hierarchy[parent])
			end
		end
	end

	table.sort(tlc)

	local sections = {}

	for _, sect in ipairs(self.config.nav or {}) do
		if sect.kind == 'class' then
			table.insert(sections, {name = sect.name, children = sect.filter})
		elseif sect.kind == 'org' then
			table.insert(sections, {name = sect.name, elements = sect.elements})
		end
	end
end

local function collect_parents(classes, class, parents)
	for _, parent in ipairs(class.inherits) do
		if not parents[parent] then
			table.insert(parents, 1, parent)

			collect_parents(classes, classes[parent], parents)
		end
	end
end

function State:prepare()
	for _, class in ipairs(self.class_list) do
		table.sort(class.properties, function(a, b)
			return a.name < b.name
		end)

		table.sort(class.statics, function(a, b)
			return a.name < b.name
		end)

		table.sort(class.methods, function(a, b)
			return a.name < b.name
		end)
	end

	table.sort(self.enumerations, function(a, b)
		return a.name < b.name
	end)

	local dump = {classes = {}, enumerations = self.enumerations, state = self}

	for _, class in ipairs(self.class_map) do
		local parents = {}

		collect_parents(self.class_map, class, parents)

		local properties = {}
		local statics = {}
		local methods = {}

		for _, parent in ipairs(parents) do
			local parent_class = self.classes[parent]

			if #parent_class.properties > 0 then
				table.insert(properties, {from = parent, list = parent_class.properties})
			end

			if #parent_class.statics > 0 then
				table.insert(statics, {from = parent, list = parent_class.statics})
			end

			if #parent_class.methods > 0 then
				table.insert(methods, {from = parent, list = parent_class.methods})
			end
		end

		if #class.properties > 0 then
			table.insert(properties, {list = class.properties})
		end

		if #class.statics > 0 then
			table.insert(statics, {list = class.statics})
		end

		if #class.methods > 0 then
			table.insert(methods, {list = class.methods})
		end

		dump.classes[class.name] = {
			description = class.description,
			constructor = class.constructor,
			properties = properties,
			statics = statics,
			methods = methods,
			name = class.name,
		}
	end

	self.prepared = dump
end

return State
