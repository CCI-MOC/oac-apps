hs = {}
if obj.status ~= nil and obj.status.conditions ~= nil then
  for _, condition in ipairs(obj.status.conditions) do
    if condition.type == "Degraded" and condition.status == "True" then
      hs.status = "Degraded"
      hs.message = condition.message
      return hs
    end
  end
  for _, condition in ipairs(obj.status.conditions) do
    if condition.type == "Available" and condition.status == "True" then
      hs.status = "Healthy"
      hs.message = condition.message
      return hs
    end
  end
end
hs.status = "Progressing"
hs.message = "Waiting for metallb to become available"
return hs