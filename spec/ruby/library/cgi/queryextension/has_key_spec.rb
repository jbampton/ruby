require_relative '../../../spec_helper'

ruby_version_is ""..."3.5" do
  require 'cgi'
  require_relative 'shared/has_key'

  describe "CGI::QueryExtension#has_key?" do
    it_behaves_like :cgi_query_extension_has_key_p, :has_key?
  end
end
