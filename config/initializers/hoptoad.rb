hoptoad_api_key = Metadata::Setting.find_setting('hoptoad_api_key').try(:value)
if hoptoad_api_key
  HoptoadNotifier.configure do |config|
    config.api_key = hoptoad_api_key
  end
end
