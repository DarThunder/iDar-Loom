local binary_heap = {}
binary_heap.__index = binary_heap

local function swap(nodes, positions, i, j)
    local node_i = nodes[i]
    local node_j = nodes[j]
    nodes[i] = node_j
    nodes[j] = node_i
    positions[node_i] = j
    positions[node_j] = i
end

function binary_heap.new(list, comp_func)
    local new_binary_heap = setmetatable({ nodes = type(list) == "table" and list or {}, positions = {} }, binary_heap)

    if list and #list > 1 then
        for i = 1, #new_binary_heap.nodes do new_binary_heap.positions[new_binary_heap.nodes[i]] = i end
        for i = math.floor(#new_binary_heap.nodes / 2), 1, -1 do new_binary_heap:heapify_down(i) end
    end

    new_binary_heap.compare = comp_func
    return new_binary_heap
end

function binary_heap:bubble_up(i)
    local nodes = self.nodes
    local positions = self.positions
    local compare = self.compare
    local parent_i = math.floor(i / 2)

    while i > 1 and compare(nodes[i], nodes[parent_i]) do
        swap(nodes, positions, i, parent_i)
        i = parent_i
        parent_i = math.floor(i / 2)
    end
end

function binary_heap:heapify_down(i)
    local nodes = self.nodes
    local positions = self.positions
    local len = #nodes
    local compare = self.compare

    while true do
        local left_i = i * 2
        local right_i = i * 2 + 1
        local smallest_i = i

        if left_i <= len and compare(nodes[left_i], nodes[smallest_i]) then smallest_i = left_i end
        if right_i <= len and compare(nodes[right_i], nodes[smallest_i]) then smallest_i = right_i end
        if smallest_i == i then break end

        swap(nodes, positions, i, smallest_i)
        i = smallest_i
    end
end

function binary_heap:insert(node)
    local i = #self.nodes + 1
    self.nodes[i] = node
    self.positions[node] = i
    self:bubble_up(i)
end

function binary_heap:pop()
    local min_node = self.nodes[1]
    self.positions[min_node] = nil
    local last_node = table.remove(self.nodes)

    if #self.nodes == 0 then return min_node end

    self.nodes[1] = last_node
    self.positions[last_node] = 1
    self:heapify_down(1)

    return min_node
end


function binary_heap:remove(value)
    local index = self.positions[value]
    if not index then return end

    self.positions[value] = nil
    local last = table.remove(self.nodes)

    if index == #self.nodes + 1 then return end

    self.nodes[index] = last
    self.positions[last] = index
    self:heapify_down(index)

    if self.nodes[index] == last then self:bubble_up(index) end
end

function binary_heap:change_key(old_value, new_value)
    local index = self.positions[old_value]

    if not index then return end

    self.nodes[index] = new_value
    self.positions[old_value] = nil
    self.positions[new_value] = index
    self:bubble_up(index)
end

return function(list, comp_func)
    return binary_heap.new(list, comp_func)
end