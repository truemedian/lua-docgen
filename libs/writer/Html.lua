local super = require('super')
local Writer = require('reader/reader_impl')

local Html = {}
Html.__name = 'Html'

function Html.create(state, class_name)
    local self = Writer.create(state, class_name)

    super(self, Html)

    return self
end

local escape_map = {['&'] = '&amp;', ['>'] = '&gt;', ['<'] = '&lt;'}
function Html:escape(str)
    return (str:gsub('[&<>]', escape_map))
end

function Html:emitType(type)
    local name = type.name
    local link = type.name

    if #type.anchor > 0 then
        link = type.name .. '#' .. type.anchor
        name = type.anchor
    end

    if type.name ~= type.name:lower() then
        if self.classes[type.name] then
            link = '<a href="/class/' .. link .. '">' .. name .. '</a>'
        else
            link = '<a href="/' .. link .. '">' .. name .. '</a>'
        end
    end

    if type.annotation then
        local annotation

        if type.name == 'number' then
            local min, max = type.annotation:match('(%d+), (%d+)')

            annotation = 'A number in thr range ' .. min .. ' to ' .. max .. ', inclusive.'
        elseif type.name == 'table' then
            local key, value = type.annotation:match('(%w+), (%w+)')

            if key and value then
                annotation = 'An table with ' .. key .. ' keys and ' .. value .. ' values.'
            else
                annotation = 'An array of ' .. type.annotation .. ' values.'
            end
        else
            annotation = type.annotation
        end

        self:write('<span class="annotated">', '\n')

        self:write('\t', link, '\n')
        self:write('<p>', self:escape(annotation), '</p>')

        self:write('\b', '</span>', '\n')
    else
        self:write(link)
    end
end

function Html:emitTypes(types, join)
    for i, typ in ipairs(types) do
        self:emitType(typ)

        if i ~= #types then
            self:write(join or ' or ')
        end
    end
end

function Html:emitNav()
    self:write('<ul>', '\n', '\t')

    

    self:write('\b', '</ul>', '\n')
end
