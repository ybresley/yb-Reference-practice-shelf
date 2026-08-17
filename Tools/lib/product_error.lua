-- User-facing errors lead with the product result. Raw implementation detail is
-- retained under one explicit support label instead of leaking into the sentence.
local product_error = {}

function product_error.details(err)
  return "Technical details for support:\n" .. tostring(err)
end

function product_error.with_details(message, err)
  return message .. "\n\n" .. product_error.details(err)
end

return product_error
