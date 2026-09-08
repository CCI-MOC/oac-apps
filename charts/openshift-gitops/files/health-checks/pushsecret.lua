hs = {}
if obj.status ~= nil and obj.status.conditions ~= nil then
  for _, condition in ipairs(obj.status.conditions) do
    if condition.type == "Ready" then
      if condition.status == "True" then
        hs.status = "Healthy"
        hs.message = condition.message
      elseif condition.message == "could not get source secret"
          and obj.status.syncedPushSecrets ~= nil
          and next(obj.status.syncedPushSecrets) ~= nil then
        hs.status = "Healthy"
        hs.message = "Source secret no longer exists (already pushed)"
      else
        hs.status = "Degraded"
        hs.message = condition.message
      end
      return hs
    end
  end
end
hs.status = "Progressing"
hs.message = "Waiting for PushSecret to sync"
return hs