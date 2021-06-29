local super = require('super')

local Writer = {}
Writer.__name = 'Reader'

function Writer.create(state)
    local self = {}

    super(self, Writer)

    self.state = state

    self.name = nil
    self.kind = nil
    self.buffer = {}

    return self
end

function Writer:reset()
    self.buffer = {}
end

function Writer:load(name, kind)
    self.kind = kind
    self.name = name
end

function Writer:write(...)
    for i = 1, select('#', ...) do
        table.insert(self.buffer, (select(i, ...)))
    end
end

function Writer:export()
    local buffer = table.concat(self.buffer)

    local tab_size = 0
    return (buffer:gsub('[\t\b\n]', function(str)
        if str == '\t' then
            tab_size = tab_size + 1
        elseif str == '\b' then
            tab_size = tab_size - 1
            assert(tab_size >= 0, 'invalid tabulation')
        else
            return '\n' .. string.rep('\t', tab_size)
        end

        return ''
    end))
end

return Writer
