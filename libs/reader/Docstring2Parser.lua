local super = require('super')
local Reader = require('reader/reader_impl')

local lpeg = require 'lpeg'
lpeg.locale(lpeg)

local lua_type, class_type, any_type, type_list
do
	local C, Cc, Cg, Cp, Ct, P = lpeg.C, lpeg.Cc, lpeg.Cg, lpeg.Cp, lpeg.Ct, lpeg.P

	lua_type = Ct(Cg(Cc 'lua', 'kind') * Cg(lpeg.lower ^ 1, 'value'))
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
		if field.name == 'p' then
			local name, param_type = field.value:match('(%S+)%s+(.+)')

			local types, leftover = parse_types(param_type)
			assert(leftover == '', 'required parameters cannot have default values')

			params.list[#params.list + 1] = {name = name, types = types}
			params.simple[#params.simple + 1] = name
		elseif field.name == 'op' then
			local name, param_type = field.value:match('(%S+)%s+(.+)')

			local types, leftover = parse_types(param_type)

			params.has_optional = true
			params.list[#params.list + 1] = {name = name, types = types, optional = true}
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

local Docstring2Parser = {}
Docstring2Parser.__name = 'Docstring2Parser'

function Docstring2Parser.create(state)
	local self = Reader.create(state)

	super(self, Docstring2Parser)

	return self
end

function Docstring2Parser:processString(chunk)
	local fields = {}

	for pos, name, value in chunk:gmatch('()@(%S+)%s+([^@]+)') do
		fields[#fields + 1] = {name = name, value = value:match('^%s*(.-)%s*$'), index = self.location + pos}
	end

	if get_field(fields, 'c') then
		local class = {}

		local inherits = {}
		local class_name = get_field(fields, 'c', true)

		for cls in class_name:gmatch('([^ x]+)') do
			table.insert(inherits, cls)
		end

		class.name = table.remove(inherits, 1)
		class.inherits = inherits
		class.description = get_field(fields, 'd', true)

		class.tags = collect_field(fields, 't', true)

		class.statics = {}
		class.methods = {}
		class.metamethods = {}
		class.properties = {}
		class.file = self.source

		if class.description == 'TODO' then
			print('Missing : Class       : ' .. self:getName())
		end

		do
			local constructor = {}

			constructor.description = ''
			constructor.params = collect_parameters(fields)

			class.constructor = constructor
		end

		self.class = class
	elseif get_field(fields, 'm') then
		local class = assert(self.class, self:getName() .. ': missing class documentation, attempted to parse method')
		local method = {}

		method.name = get_field(fields, 'm', true)
		method.description = get_field(fields, 'd', true)

		method.params = collect_parameters(fields)
		method.returns = collect_field(fields, 'r', false, any_type)

		method.tags = collect_field(fields, 't', true)

		if method.description == 'TODO' then
			print('Missing : Method      : ' .. self:getName() .. ' ' .. method.name)
		end

		if method.tags.static then
			table.insert(class.statics, method)
		else
			table.insert(class.methods, method)
		end
	elseif get_field(fields, 'p') then
		local class = assert(self.class, self:getName() .. ': missing class documentation, attempted to parse property')
		local property = {}

		local name, leftover1 = get_field(fields, 'p', true):match('^(%W+)%s+(.+)')
		local types, leftover2 = parse_types(leftover1)

		property.name = name
		property.types = types
		property.description = leftover2

		table.insert(class.properties, property)
	else
		error(self:getName() .. ': unknown documentation string, no identifying field')
	end
end

function Docstring2Parser:processClass()
	for start, comment in self.content:gmatch('--%[=%[%s*()(.-)%s*%]=%]') do
		self.location = start

		self:processString(comment)
	end

	if self.class then
		self.state:newClass(self.class)
	end
end

function Docstring2Parser:processEnums()
	local enums = {}

	for enum, comment in self.content:gmatch('enums.(%S+)%s*=%s*enum%s*{(.-)}') do
		local tbl = {}

		for name, value in comment:gmatch('\n%s+(%S+)%s*=%s*([^,\n]+)') do
			tbl[name] = value:gsub('\'', '"')
		end

		enums[enum] = tbl
	end

	self.state:addEnumerations(enums)
end

return Docstring2Parser
