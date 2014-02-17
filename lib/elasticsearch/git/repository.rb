require 'active_support/concern'
require 'active_model'
require 'elasticsearch'
require 'elasticsearch/model'
require 'rugged'
require 'linguist'

module Elasticsearch
  module Git
    module Repository
      extend ActiveSupport::Concern

      included do
        include Elasticsearch::Git::Model

        mapping do
          indexes :blob do
            indexes :id,          type: :string, index_options: 'offsets', search_analyzer: :human_analyzer,  index_analyzer: :human_analyzer
            indexes :rid,         type: :string, index: :not_analyzed
            indexes :oid,         type: :string, index_options: 'offsets', search_analyzer: :sha_analyzer,    index_analyzer: :sha_analyzer
            indexes :commit_sha,  type: :string, index_options: 'offsets', search_analyzer: :sha_analyzer,    index_analyzer: :sha_analyzer
            indexes :content,     type: :string, index_options: 'offsets', search_analyzer: :code_analyzer,   index_analyzer: :human_analyzer
          end
          indexes :commit do
            indexes :id,          type: :string, index_options: 'offsets', search_analyzer: :human_analyzer,  index_analyzer: :human_analyzer
            indexes :rid,         type: :string, index: :not_analyzed
            indexes :sha,         type: :string, index_options: 'offsets', search_analyzer: :sha_analyzer,    index_analyzer: :sha_analyzer
            indexes :author do
              indexes :name,      type: :string, index_options: 'offsets', search_analyzer: :code_analyzer,    index_analyzer: :human_analyzer
              indexes :email,     type: :string, index_options: 'offsets', search_analyzer: :code_analyzer,    index_analyzer: :human_analyzer
              indexes :time,      type: :date
            end
            indexes :commiter do
              indexes :name,      type: :string, index_options: 'offsets', search_analyzer: :code_analyzer,    index_analyzer: :human_analyzer
              indexes :email,     type: :string, index_options: 'offsets', search_analyzer: :code_analyzer,    index_analyzer: :human_analyzer
              indexes :time,      type: :date
            end
            indexes :message,    type: :string, index_options: 'offsets', search_analyzer: :code_analyzer,     index_analyzer: :human_analyzer
          end
        end

        # Indexing all text-like blobs in repository
        #
        # All data stored in global index
        # Repository can be selected by 'rid' field
        # If you want - this field can be used for store 'project' id
        #
        # blob {
        #   id - uniq id of blob from all repositories
        #   oid - blob id in repository
        #   content - blob content
        #   commit_sha - last actual commit sha
        # }
        #
        # For search from blobs use type 'blob'
        def index_blobs(from_rev: nil, to_rev: nil)

          if to_rev.present?
            begin
              raise unless repository_for_indexing.lookup(to_rev).type == :commit
            rescue
              raise ArgumentError, "'to_rev': '#{to_rev}' is a incorrect commit sha."
            end
          else
            to_rev = repository_for_indexing.head.target
          end

          target_sha = to_rev

          if from_rev.present?
            begin
              raise unless repository_for_indexing.lookup(from_rev).type == :commit
            rescue
              raise ArgumentError, "'from_rev': '#{from_rev}' is a incorrect commit sha."
            end

            diff = repository_for_indexing.diff(from_rev, to_rev)
            diff.deltas.reverse.each do |delta|
              if delta.status == :deleted
                b = LiteBlob.new(repository_for_indexing, delta.old_file)
                delete_from_index_blob(b)
              else
                b = LiteBlob.new(repository_for_indexing, delta.new_file)
                index_blob(b, target_sha)
              end
            end
          else
            if repository_for_indexing.bare?
              recurse_blobs_index(repository_for_indexing.lookup(target_sha).tree, target_sha)
            else
              repository_for_indexing.index.each do |blob|
                b = LiteBlob.new(repository_for_indexing, blob)
                index_blob(b, target_sha)
              end
            end
          end
        end

        # Indexing bare repository via walking through tree
        def recurse_blobs_index(tree, target_sha, path = "")
          tree.each_blob do |blob|
            blob[:path] = path + blob[:name]
            b = LiteBlob.new(repository_for_indexing, blob)
            index_blob(b, target_sha)
          end

          tree.each_tree do |nested_tree|
            recurse_blobs_index(repository_for_indexing.lookup(nested_tree[:oid]), target_sha, "#{path}#{nested_tree[:name]}/")
          end
        end

        def index_blob(blob, target_sha)
          if blob.text?
            client_for_indexing.index \
              index: "#{self.class.index_name}",
              type: "repository",
              id: "#{repository_id}_#{blob.path}",
              body: {
                blob: {
                  type: "blob",
                  oid: blob.id,
                  rid: repository_id,
                  content: blob.data,
                  commit_sha: target_sha
                }
              }
          end
        end

        def delete_from_index_blob(blob)
          if blob.text?
            begin
              client_for_indexing.delete \
                index: "#{self.class.index_name}",
                type: "repository",
                id: "#{repository_id}_#{blob.path}"
            rescue Elasticsearch::Transport::Transport::Errors::NotFound
              return true
            end
          end
        end

        # Indexing all commits in repository
        #
        # All data stored in global index
        # Repository can be filtered by 'rid' field
        # If you want - this field can be used git store 'project' id
        #
        # commit {
        #  sha - commit sha
        #  author {
        #    name - commit author name
        #    email - commit author email
        #    time - commit time
        #  }
        #  commiter {
        #    name - committer name
        #    email - committer email
        #    time - commit time
        #  }
        #  message - commit message
        # }
        #
        # For search from commits use type 'commit'
        def index_commits(from_rev: nil, to_rev: nil)
          if from_rev.present? && to_rev.present?
            begin
              raise unless repository_for_indexing.lookup(from_rev).type == :commit
              raise unless repository_for_indexing.lookup(from_rev).type == :commit
            rescue
              raise ArgumentError, "'from_rev': '#{from_rev}' is a incorrect commit sha."
            end

            repository_for_indexing.walk(from_rev, to_rev).each do |commit|
              index_commit(commit)
            end
          else
            repository_for_indexing.each_id do |oid|
              obj = repository_for_indexing.lookup(oid)
              if obj.type == :commit
                index_commit(obj)
              end
            end
          end
        end

        def index_commit(commit)
          client_for_indexing.index \
            index: "#{self.class.index_name}",
            type: "repository",
            id: "#{repository_id}_#{commit.oid}",
            body: {
              commit: {
                type: "commit",
                rid: repository_id,
                sha: commit.oid,
                author: commit.author,
                committer: commit.committer,
                message: commit.message
              }
            }
        end

        # Representation of repository as indexed json
        # Attention: It can be very very very huge hash
        def as_indexed_json(options = {})
          ij = {}
          ij[:blobs] = index_blobs_array
          ij[:commits] = index_commits_array
          ij
        end

        # Indexing blob from current index
        def index_blobs_array
          result = []

          target_sha = repository_for_indexing.head.target

          if repository_for_indexing.bare?
            tree = repository_for_indexing.lookup(target_sha).tree
            result.push(recurse_blobs_index_hash(tree))
          else
            repository_for_indexing.index.each do |blob|
              b = EasyBlob.new(repository_for_indexing, blob)
              result.push(
                {
                  type: 'blob',
                  id: "#{target_sha}_#{b.path}",
                  rid: repository_id,
                  oid: b.id,
                  content: b.data,
                  commit_sha: target_sha
                }
              ) if b.text?
            end
          end

          result
        end

        def recurse_blobs_index_hash(tree, path = "")
          result = []

          tree.each_blob do |blob|
            blob[:path] = path + blob[:name]
            b = LiteBlob.new(repository_for_indexing, blob)
            result.push(
              {
                type: 'blob',
                id: "#{repository_for_indexing.head.target}_#{path}#{blob[:name]}",
                rid: repository_id,
                oid: b.id,
                content: b.data,
                commit_sha: repository_for_indexing.head.target
              }
            ) if b.text?
          end

          tree.each_tree do |nested_tree|
            result.push(recurse_blobs_index_hash(repository_for_indexing.lookup(nested_tree[:oid]), "#{nested_tree[:name]}/"))
          end

          result.flatten
        end

        # Lookup all object ids for commit objects
        def index_commits_array
          res = []

          repository_for_indexing.each_id do |oid|
            obj = repository_for_indexing.lookup(oid)
            if obj.type == :commit
              res.push(
                {
                  type: 'commit',
                  sha: obj.oid,
                  author: obj.author,
                  committer: obj.committer,
                  message: obj.message
                }
              )
            end
          end

          res
        end

        # Repository id used for identity data from different repositories
        # Update this value if need
        def set_repository_id id = nil
          @repository_id = id || path_to_repo
        end

        # For Overwrite
        def repository_id
          @repository_id
        end

        unless defined?(path_to_repo)
          def path_to_repo
            if @path_to_repo.blank?
              raise NotImplementedError, 'Please, define "path_to_repo" method, or set "path_to_repo" via "repository_for_indexing" method'
            else
              @path_to_repo
            end
          end
        end

        def repository_for_indexing(repo_path = "")
          @path_to_repo ||= repo_path
          set_repository_id
          Rugged::Repository.new(@path_to_repo)
        end

        def client_for_indexing
          @client_for_indexing ||= Elasticsearch::Client.new log: true
        end
      end

      module ClassMethods
        def search(query, type: :all, page: 1, per: 20, options: {})
          results = { blobs: [], commits: []}
          case type.to_sym
          when :all
            results[:blobs] = search_blob(query, page: page, per: per, options: options)
            results[:commits] = search_commit(query, page: page, per: per, options: options)
          when :blob
            results[:blobs] = search_blob(query, page: page, per: per, options: options)
          when :commit
            results[:commits] = search_commit(query, page: page, per: per, options: options)
          end

          results
        end

        def search_commit(query, page: 1, per: 20, options: {})
          page ||= 1

          fields = %w(message^10 sha^5 author.name^2 author.email^2 committer.name committer.email).map {|i| "commit.#{i}"}

          query_hash = {
            query: {
              filtered: {
                query: {
                  multi_match: {
                    fields: fields,
                    query: "#{query}",
                    operator: :and
                  }
                },
              },
            },
            size: per,
            from: per * (page - 1)
          }

          if query.blank?
            query_hash[:query][:filtered][:query] = { match_all: {}}
            query_hash[:track_scores] = true
          end

          if options[:highlight]
            query_hash[:highlight] = { fields: options[:in].inject({}) { |a, o| a[o.to_sym] = {} } }
          end

          self.__elasticsearch__.search(query_hash).results
        end

        def search_blob(query, type: :all, page: 1, per: 20, options: {})
          page ||= 1

          query_hash = {
            query: {
              match: {
                'blob.content' => {
                  query: "#{query}",
                  operator: :and
                }
              }
            },
            size: per,
            from: per * (page - 1)
          }

          if options[:highlight]
            query_hash[:highlight] = { fields: options[:in].inject({}) { |a, o| a[o.to_sym] = {} } }
          end

          self.__elasticsearch__.search(query_hash).results
        end
      end
    end

    class LiteBlob
      include Linguist::BlobHelper

      attr_accessor :id, :name, :path, :data, :commit_id

      def initialize(repo, raw_blob_hash)
        @id = raw_blob_hash[:oid]
        @path = raw_blob_hash[:path]
        @name = @path.split("/").last
        @data = encode!(repo.lookup(@id).content)
      end

      def encode!(message)
        return nil unless message.respond_to? :force_encoding

        # if message is utf-8 encoding, just return it
        message.force_encoding("UTF-8")
        return message if message.valid_encoding?

        # return message if message type is binary
        detect = CharlockHolmes::EncodingDetector.detect(message)
        return message.force_encoding("BINARY") if detect && detect[:type] == :binary

        # encoding message to detect encoding
        if detect && detect[:encoding]
          message.force_encoding(detect[:encoding])
        end

        # encode and clean the bad chars
        message.replace clean(message)
      rescue
        encoding = detect ? detect[:encoding] : "unknown"
        "--broken encoding: #{encoding}"
      end

      private

      def clean(message)
        message.encode("UTF-16BE", :undef => :replace, :invalid => :replace, :replace => "")
        .encode("UTF-8")
        .gsub("\0".encode("UTF-8"), "")
      end
    end
  end
end