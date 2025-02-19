#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) 2012-2022 the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++

require 'spec_helper'

describe Storages::Peripherals::StorageRequests, webmock: true do
  using Storages::Peripherals::ServiceResultRefinements

  let(:user) { build_stubbed(:user) }

  let(:url) { 'https://example.com' }
  let(:origin_user_id) { 'admin' }

  let(:storage) do
    storage = instance_double(::Storages::Storage)
    allow(storage).to receive(:oauth_client).and_return(instance_double(OAuthClient))
    allow(storage).to receive(:provider_type).and_return(::Storages::Storage::PROVIDER_TYPE_NEXTCLOUD)
    allow(storage).to receive(:host).and_return(url)
    storage
  end

  let(:token) do
    token = instance_double(OAuthClientToken)
    allow(token).to receive(:origin_user_id).and_return(origin_user_id)
    allow(token).to receive(:access_token).and_return('xyz')
    token
  end

  let(:connection_manager) do
    connection_manager = instance_double(::OAuthClients::ConnectionManager)
    allow(connection_manager).to receive(:get_access_token).and_return(ServiceResult.success(result: token))
    allow(connection_manager).to receive(:request_with_token_refresh).and_yield(token)
    connection_manager
  end

  subject { described_class.new(storage:) }

  describe '#download_link_query' do
    let(:file_link) do
      Struct.new(:file_link) do
        def origin_id
          42
        end

        def origin_name
          'example.md'
        end
      end.new
    end
    let(:download_token) { "8dM3dC9iy1N74F5AJ0ClnjSF4dWTxfymVy1HTXBh8rbZVM81CpcBJaIYZvmR" }
    let(:uri) do
      URI::join(url, "/index.php/apps/integration_openproject/direct/#{download_token}/#{CGI.escape(file_link.origin_name)}")
    end
    let(:json) do
      {
        ocs: {
          meta: {
            status: 'ok',
            statuscode: 200,
            message: 'OK'
          },
          data: {
            url: "https://example.com/remote.php/direct/#{download_token}"
          }
        }
      }.to_json
    end

    before do
      allow(::OAuthClients::ConnectionManager).to receive(:new).and_return(connection_manager)
      stub_request(:post, "#{url}/ocs/v2.php/apps/dav/api/v1/direct")
        .to_return(status: 200, body: json, headers: {})
    end

    describe 'with Nextcloud storage type selected' do
      it 'must return a download link URL' do
        subject
          .download_link_query(user:)
          .match(
            on_success: ->(query) do
              result = query.call(file_link)
              expect(result).to be_success
              expect(result.result).to be_eql(uri)
            end,
            on_failure: ->(error) do
              raise "Files query could not be created: #{error}"
            end
          )
      end
    end

    describe 'with not supported storage type selected' do
      before do
        allow(storage).to receive(:provider_type).and_return('not_supported_storage_type'.freeze)
      end

      it 'must raise ArgumentError' do
        expect { subject.download_link_query(user:) }.to raise_error(ArgumentError)
      end
    end

    describe 'with missing OAuth token' do
      before do
        allow(connection_manager).to receive(:get_access_token).and_return(ServiceResult.failure)
      end

      it 'must return ":not_authorized" ServiceResult' do
        expect(subject.download_link_query(user:)).to be_failure
      end
    end

    describe 'with outbound request returning 200 and an empty body' do
      before do
        stub_request(:post, "#{url}/ocs/v2.php/apps/dav/api/v1/direct").to_return(status: 200, body: '')
      end

      it 'must return :not_authorized ServiceResult' do
        subject
          .download_link_query(user:)
          .match(
            on_success: ->(query) do
              result = query.call(file_link)
              expect(result).to be_failure
              expect(result.errors.code).to be(:not_authorized)
            end,
            on_failure: ->(error) do
              raise "Files query could not be created: #{error}"
            end
          )
      end
    end

    shared_examples_for 'outbound is failing' do |code = 500, symbol = :error|
      describe "with outbound request returning #{code}" do
        before do
          stub_request(:post, "#{url}/ocs/v2.php/apps/dav/api/v1/direct").to_return(status: code)
        end

        it "must return :#{symbol} ServiceResult" do
          subject
            .download_link_query(user:)
            .match(
              on_success: ->(query) do
                result = query.call(file_link)
                expect(result).to be_failure
                expect(result.errors.code).to be(symbol)
              end,
              on_failure: ->(error) do
                raise "Files query could not be created: #{error}"
              end
            )
        end
      end
    end

    include_examples 'outbound is failing', 404, :not_found
    include_examples 'outbound is failing', 401, :not_authorized
    include_examples 'outbound is failing', 500, :error
  end

  describe '#files_query' do
    let(:xml) { create(:webdav_data) }

    before do
      allow(::OAuthClients::ConnectionManager).to receive(:new).and_return(connection_manager)
      stub_request(:propfind, "#{url}/remote.php/dav/files/#{origin_user_id}")
        .to_return(status: 207, body: xml, headers: {})
    end

    describe 'with Nextcloud storage type selected' do
      it 'must return a list of files when called' do
        subject
          .files_query(user:)
          .match(
            on_success: ->(query) do
              result = query.call(nil)
              expect(result).to be_success
              expect(result.result.size).to eq(3)
            end,
            on_failure: ->(error) do
              raise "Files query could not be created: #{error}"
            end
          )
      end

      it 'must return a named directory' do
        subject
          .files_query(user:)
          .match(
            on_success: ->(query) do
              result = query.call(nil)
              expect(result).to be_success
              expect(result.result[0].name).to eq('Folder1')
              expect(result.result[0].mime_type).to eq('application/x-op-directory')
              expect(result.result[0].id).to eq('11')
            end,
            on_failure: ->(error) do
              raise "Files query could not be created: #{error}"
            end
          )
      end

      it 'must return a named file' do
        subject
          .files_query(user:)
          .match(
            on_success: ->(query) do
              result = query.call(nil)
              expect(result).to be_success
              expect(result.result[1].name).to eq('README.md')
              expect(result.result[1].mime_type).to eq('text/markdown')
              expect(result.result[1].id).to eq('12')
            end,
            on_failure: ->(error) do
              raise "Files query could not be created: #{error}"
            end
          )
      end

      describe 'with parent query parameter' do
        let(:parent) { '/Photos/Birds' }
        let(:request_url) { "#{url}/remote.php/dav/files/#{origin_user_id}#{parent}" }

        before do
          stub_request(:propfind, request_url).to_return(status: 207, body: xml, headers: {})
        end

        it do
          subject
            .files_query(user:)
            .match(
              on_success: ->(query) { query.call(parent) },
              on_failure: ->(error) { raise "Files query could not be created: #{error}" }
            )

          assert_requested(:propfind, request_url)
        end
      end
    end

    describe 'with not supported storage type selected' do
      before do
        allow(storage).to receive(:provider_type).and_return('not_supported_storage_type'.freeze)
      end

      it 'must raise ArgumentError' do
        expect { subject.files_query(user:) }.to raise_error(ArgumentError)
      end
    end

    describe 'with missing OAuth token' do
      before do
        allow(connection_manager).to receive(:get_access_token).and_return(ServiceResult.failure)
      end

      it 'must return ":not_authorized" ServiceResult' do
        expect(subject.files_query(user:)).to be_failure
      end
    end

    shared_examples_for 'outbound is failing' do |code = 500, symbol = :error|
      describe "with outbound request returning #{code}" do
        before do
          stub_request(:propfind, "#{url}/remote.php/dav/files/#{origin_user_id}").to_return(status: code)
        end

        it "must return :#{symbol} ServiceResult" do
          subject
            .files_query(user:)
            .match(
              on_success: ->(query) do
                result = query.call(nil)
                expect(result).to be_failure
                expect(result.errors.code).to be(symbol)
              end,
              on_failure: ->(error) do
                raise "Files query could not be created: #{error}"
              end
            )
        end
      end
    end

    include_examples 'outbound is failing', 404, :not_found
    include_examples 'outbound is failing', 401, :not_authorized
    include_examples 'outbound is failing', 500, :error
  end

  describe '#upload_link_query' do
    let(:query_payload) do
      Struct.new(:fileName, :parent).new("ape.png", "/Pictures")
    end

    let(:uri) do
      URI::join(url, "/public.php/webdav/#{query_payload[:fileName]}")
    end

    let(:share_id) { 37 }

    before do
      allow(::OAuthClients::ConnectionManager).to receive(:new).and_return(connection_manager)
      stub_request(:post, "#{url}/ocs/v2.php/apps/files_sharing/api/v1/shares")
        .with(
          body: hash_including(
            {
              shareType: 3,
              path: query_payload.parent,
              expireDate: Date.tomorrow.iso8601
            }
          )
        )
        .to_return(
          status: 200,
          body: {
            ocs: {
              data: {
                id: share_id,
                token: 'jJ6t8yHe7CEX5Bp'
              }
            }
          }.to_json
        )
      stub_request(:put, "#{url}/ocs/v2.php/apps/files_sharing/api/v1/shares/#{share_id}")
        .with(body: { permissions: 4 })
        .to_return(status: 200, body: {}.to_json)
    end

    describe 'with Nextcloud storage type selected' do
      it 'must return an upload link URL' do
        subject
          .upload_link_query(user:, finalize_url: nil)
          .match(
            on_success: ->(query) do
              query.call(query_payload).match(
                on_success: ->(link) {
                  expect(link.destination.path).to be_eql("/public.php/webdav/#{query_payload.fileName}")
                  expect(link.destination.host).to be_eql(URI(url).host)
                  expect(link.destination.scheme).to be_eql(URI(url).scheme)
                  expect(link.destination.user).not_to be_nil
                  expect(link.destination.password).not_to be_nil
                },
                on_failure: ->(error) {
                  raise "Files query could not be executed: #{error}"
                }
              )
            end,
            on_failure: ->(error) do
              raise "Files query could not be created: #{error}"
            end
          )
      end
    end

    describe 'with not supported storage type selected' do
      before do
        allow(storage).to receive(:provider_type).and_return('not_supported_storage_type'.freeze)
      end

      it 'must raise ArgumentError' do
        expect { subject.download_link_query(user:) }.to raise_error(ArgumentError)
      end
    end

    describe 'with missing OAuth token' do
      before do
        allow(connection_manager).to receive(:get_access_token).and_return(ServiceResult.failure)
      end

      it 'must return ":not_authorized" ServiceResult' do
        expect(subject.download_link_query(user:)).to be_failure
      end
    end

    describe 'with first outbound request returning 200 and an empty body' do
      before do
        stub_request(:post, "#{url}/ocs/v2.php/apps/files_sharing/api/v1/shares")
          .with(
            body: hash_including(
              {
                shareType: 3,
                path: query_payload.parent,
                expireDate: Date.tomorrow.iso8601
              }
            )
          )
          .to_return(status: 200)
      end

      it 'must return :not_authorized ServiceResult' do
        subject
          .upload_link_query(user:, finalize_url: nil)
          .match(
            on_success: ->(query) do
              result = query.call(query_payload)
              expect(result).to be_failure
              expect(result.errors.code).to be(:not_authorized)
            end,
            on_failure: ->(error) do
              raise "Files query could not be created: #{error}"
            end
          )
      end
    end

    describe 'with second outbound request returning 200 and an empty body' do
      before do
        stub_request(:put, "#{url}/ocs/v2.php/apps/files_sharing/api/v1/shares/#{share_id}")
          .with(body: { permissions: 4 })
          .to_return(status: 200)
      end

      it 'must return :not_authorized ServiceResult' do
        subject
          .upload_link_query(user:, finalize_url: nil)
          .match(
            on_success: ->(query) do
              result = query.call(query_payload)
              expect(result).to be_failure
              expect(result.errors.code).to be(:not_authorized)
            end,
            on_failure: ->(error) do
              raise "Files query could not be created: #{error}"
            end
          )
      end
    end

    shared_examples_for 'outbound is failing' do |method = :get, path = '', code = 500, symbol = :error|
      describe "with outbound request returning #{code}" do
        before do
          stub_request(method, "#{url}/ocs/v2.php/apps/files_sharing/api/v1/shares#{path}").to_return(status: code)
        end

        it "must return :#{symbol} ServiceResult" do
          subject
            .upload_link_query(user:, finalize_url: nil)
            .match(
              on_success: ->(query) do
                result = query.call(query_payload)
                expect(result).to be_failure
                expect(result.errors.code).to be(symbol)
              end,
              on_failure: ->(error) do
                raise "Files query could not be created: #{error}"
              end
            )
        end
      end
    end

    include_examples 'outbound is failing', :post, '', 404, :not_found
    include_examples 'outbound is failing', :post, '', 401, :not_authorized
    include_examples 'outbound is failing', :post, '', 500, :error
    include_examples 'outbound is failing', :put, '/37', 404, :not_found
    include_examples 'outbound is failing', :put, '/37', 401, :not_authorized
    include_examples 'outbound is failing', :put, '/37', 500, :error
  end
end
