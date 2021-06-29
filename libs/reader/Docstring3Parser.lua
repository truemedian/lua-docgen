local super = require('super')
local Reader = require('reader/reader_impl')

local lpeg = require 'lpeg'
lpeg.locale(lpeg)

local lua_type, class_type, any_type, type_list
do
	local C, Cc, Cg, Cp, Ct, P = lpeg.C, lpeg.Cc, lpeg.Cg, lpeg.Cp, lpeg.Ct, lpeg.P

	lua_type = Ct(Cg(Cc 'lua', 'kind') * Cg(lpeg.lower ^ 1, 'value') *
              					Cg(P '[' * C((P(1) - P ']') ^ 1) * P ']', 'annotation') ^ -1)
	class_type = Ct(Cg(Cc 'class', 'kind') * Cg(lpeg.upper * lpeg.alpha ^ 0, 'value'))

	any_type = class_type + lua_type
	type_list = Ct((any_type * ',' * lpeg.space ^ 0) ^ 0 * any_type) * lpeg.space ^ 0 * Cp()
end

local function parse_types(str)
	local tbl, left = type_list:match(str)

	return tbl, str:sub(left)
end

local function get_field(fields, name, fetch_value)
	for _, field in ipairs(fields) do
		if field.name == name then
			return fetch_value and field.value or field
		end
	end
end

local function collect_parameters(fields)
	local params = {list = {}, simple = {}}

	params.has_optional = false
	for _, field in ipairs(fields) do
		if field.name == 'param' then
			local name, param_type = field.value:match('(%S+)%s+(.+)')

			local types, leftover = parse_types(param_type)
			assert(leftover == '', 'required parameters cannot have default values')

			params.list[#params.list + 1] = {name = name, types = types}
			params.simple[#params.simple + 1] = name
		elseif field.name == 'param?' then
			local name, param_type = field.value:match('(%S+)%s+(.+)')

			local types, leftover = parse_types(param_type)

			params.has_optional = true
			params.list[#params.list + 1] = {name = name, types = types, default = leftover, optional = true}
			params.simple[#params.simple + 1] = name
		end
	end

	return params
end

local function collect_field(fields, name, map, pattern)
	local tbl = {}

	for _, field in ipairs(fields) do
		if field.name == name then
			local value = field.value:match('(%S+)')

			if map then
				tbl[value] = true
			else
				tbl[#tbl + 1] = pattern and pattern:match(value) or value
			end
		end
	end

	return tbl
end

local Docstring3Parser = {}
Docstring3Parser.__name = 'Docstring3Parser'

function Docstring3Parser.create(state)
	local self = Reader.create(state)

	super(self, Docstring3Parser)

	return self
end

function Docstring3Parser:processString(chunk)
	local fields = {}

	for pos, name, value in chunk:gmatch('()@(%S+)%s+([^@]+)') do
		fields[#fields + 1] = {name = name, value = value:match('^%s*(.-)%s*$'), index = self.location + pos}
	end

	if get_field(fields, 'class') then
		local class = {}

		class.name = get_field(fields, 'class', true)
		class.inherits = collect_field(fields, 'inherits', false)
		class.description = get_field(fields, 'description', true)

		class.tags = collect_field(fields, 'tag', true)

		class.statics = {}
		class.methods = {}
		class.metamethods = {}
		class.properties = {}
		class.file = self.source

		if class.description == 'TODO' then
			print('Missing : Class       : ' .. self:getName())
		end

		self.class = class
	elseif get_field(fields, 'constructor') then
		local class = assert(self.class, self:getName() .. ': missing class documentation, attempted to parse constructor')
		local constructor = {}

		constructor.description = get_field(fields, 'description', true)
		constructor.params = collect_parameters(fields)

		constructor.tags = collect_field(fields, 'tag', true)

		if constructor.description == 'TODO' and (not class.tags.internal and not class.tags.abstract) then
			print('Missing : Constructor : ' .. self:getName() .. ' __init')
		end

		class.constructor = constructor
	elseif get_field(fields, 'metamethod') then
		local class = assert(self.class, self:getName() .. ': missing class documentation, attempted to parse metamethod')
		local metamethod = {}

		metamethod.name = get_field(fields, 'metamethod', true)
		metamethod.description = get_field(fields, 'description', true)

		table.insert(class.metamethods, metamethod)
	elseif get_field(fields, 'method') then
		local class = assert(self.class, self:getName() .. ': missing class documentation, attempted to parse method')
		local method = {}

		method.name = get_field(fields, 'method', true)
		method.description = get_field(fields, 'description', true)

		method.params = collect_parameters(fields)
		method.returns = collect_field(fields, 'returns', false, any_type)

		method.tags = collect_field(fields, 'tag', true)

		if method.description == 'TODO' then
			print('Missing : Method      : ' .. self:getName() .. ' ' .. method.name)
		end

		table.insert(class.methods, method)
	elseif get_field(fields, 'static') then
		local class = assert(self.class, self:getName() .. ': missing class documentation, attempted to parse static method')
		local static = {}

		static.name = get_field(fields, 'static', true)
		static.description = get_field(fields, 'description', true)

		static.params = collect_parameters(fields)
		static.returns = collect_field(fields, 'returns', false, any_type)

		static.tags = collect_field(fields, 'tag', true)

		if static.description == 'TODO' then
			print('Missing : Static      : ' .. self:getName() .. ' ' .. static.name)
		end

		table.insert(class.statics, static)
	elseif get_field(fields, 'property') then
		local class = assert(self.class, self:getName() .. ': missing class documentation, attempted to parse property')
		local property = {}

		local types, leftover = parse_types(get_field(fields, 'type', true))
		assert(leftover == '', 'properties cannot have default values')

		property.name = get_field(fields, 'property', true)
		property.types = types
		property.description = get_field(fields, 'description', true)

		if property.description == 'TODO' then
			print('Missing : Property    : ' .. self:getName() .. ' ' .. property.name)
		end

		table.insert(class.properties, property)
	else
		error(self:getName() .. ': unknown documentation string, no identifying field')
	end
end

function Docstring3Parser:processClass()
	for start, comment in self.content:gmatch('--%[=%[%s*()(.-)%s*%]=%]') do
		self.location = start

		self:processString(comment)
	end

	if self.class then
		self.state:newClass(self.class)
	end
end

function Docstring3Parser:processEnums()
	local enums = {}

	for enum, comment in self.content:gmatch('proxy.(%S+)%s*=%s*{(.-)}') do
		local tbl = {}

		for name, value in comment:gmatch('\n%s+(%S+)%s*=%s*([^,\n]+)') do
			tbl[name] = value:gsub('\'', '"')
		end

		enums[enum] = tbl
	end

	self.state:addEnumerations(enums)
end

return Docstring3Parser
