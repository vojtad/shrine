# frozen_string_literal: true

class Shrine
  module Plugins
    # Documentation lives in [doc/plugins/derivatives.md] on GitHub.
    #
    # [doc/plugins/derivatives.md]: https://github.com/shrinerb/shrine/blob/master/doc/plugins/derivatives.md
    module Derivatives
      LOG_SUBSCRIBER = -> (event) do
        Shrine.logger.info "Derivatives (#{event.duration}ms) – #{{
          processor:         event[:processor],
          processor_options: event[:processor_options],
          uploader:          event[:uploader],
        }.inspect}"
      end

      def self.load_dependencies(uploader, versions_compatibility: false, **)
        uploader.plugin :default_url

        AttacherMethods.prepend(VersionsCompatibility) if versions_compatibility
      end

      def self.configure(uploader, log_subscriber: LOG_SUBSCRIBER, **opts)
        uploader.opts[:derivatives] ||= { processors: {}, storage: proc { store_key } }
        uploader.opts[:derivatives].merge!(opts)

        # instrumentation plugin integration
        uploader.subscribe(:derivatives, &log_subscriber) if uploader.respond_to?(:subscribe)
      end

      module AttachmentMethods
        def initialize(name, **options)
          super

          define_method(:"#{name}_derivatives") do |*args|
            send(:"#{name}_attacher").get_derivatives(*args)
          end
        end
      end

      module AttacherClassMethods
        # Registers a derivatives processor on the attacher class.
        #
        #     Shrine::Attacher.derivatives_processor :thumbnails do |original|
        #       # ...
        #     end
        def derivatives_processor(name, &block)
          shrine_class.opts[:derivatives][:processors][name.to_sym] = block
        end

        # Specifies default storage to which derivatives will be uploaded.
        #
        #     Shrine::Attacher.derivatives_storage :other_store
        #     # or
        #     Shrine::Attacher.derivatives_storage do |name|
        #       if name == :thumbnail
        #         :thumbnail_store
        #       else
        #         :store
        #       end
        #     end
        def derivatives_storage(storage_key = nil, &block)
          fail ArgumentError, "storage key or block needs to be provided" unless storage_key || block

          shrine_class.opts[:derivatives][:storage] = storage_key || block
        end
      end

      module AttacherMethods
        attr_reader :derivatives

        # Adds the ability to accept derivatives.
        def initialize(derivatives: {}, **options)
          super(**options)

          @derivatives       = derivatives
          @derivatives_mutex = Mutex.new
        end

        # Convenience method for accessing derivatives.
        #
        #     photo.image_derivatives[:thumb] #=> #<Shrine::UploadedFile>
        #     # can be shortened to
        #     photo.image(:thumb) #=> #<Shrine::UploadedFile>
        def get(*path)
          return super if path.empty?

          get_derivatives(*path)
        end

        # Convenience method for accessing derivatives.
        #
        #     photo.image_derivatives.dig(:thumbnails, :large)
        #     # can be shortened to
        #     photo.image_derivatives(:thumbnails, :large)
        def get_derivatives(*path)
          return derivatives if path.empty?

          path = derivative_path(path)

          derivatives.dig(*path)
        end

        # Allows generating a URL to the derivative by passing the derivative
        # name.
        #
        #     attacher.add_derivatives(thumb: thumb)
        #     attacher.url(:thumb) #=> "https://example.org/thumb.jpg"
        def url(*path, **options)
          return super if path.empty?

          path = derivative_path(path)

          url   = derivatives.dig(*path)&.url(**options)
          url ||= default_url(**options, derivative: path)
          url
        end

        # In addition to promoting the main file, also promotes any cached
        # derivatives. This is useful when these derivatives are being created
        # as part of a direct upload.
        #
        #     attacher.assign(io)
        #     attacher.add_derivative(:thumb, file, storage: :cache)
        #     attacher.promote
        #     attacher.stored?(attacher.derivatives[:thumb]) #=> true
        def promote(background: false, **options)
          super
          promote_derivatives unless background
        end

        # Uploads any cached derivatives to permanent storage.
        def promote_derivatives(**options)
          stored_derivatives = map_derivative(derivatives) do |path, derivative|
            if cached?(derivative)
              upload_derivative(path, derivative, **options)
            else
              derivative
            end
          end

          set_derivatives { stored_derivatives } unless derivatives == stored_derivatives
        end

        # In addition to deleting the main file it also deletes any derivatives.
        #
        #     attacher.add_derivatives(thumb: thumb)
        #     attacher.derivatives[:thumb].exists? #=> true
        #     attacher.destroy
        #     attacher.derivatives[:thumb].exists? #=> false
        def destroy(background: false, **options)
          super
          delete_derivatives unless background
        end

        # Deletes given hash of uploaded files.
        #
        #     attacher.delete_derivatives(thumb: uploaded_file)
        #     uploaded_file.exists? #=> false
        def delete_derivatives(derivatives = self.derivatives)
          map_derivative(derivatives) { |_, derivative| derivative.delete }
        end

        # Uploads given hash of files and adds uploaded files to the
        # derivatives hash.
        #
        #     attacher.derivatives #=>
        #     # {
        #     #   thumb: #<Shrine::UploadedFile>,
        #     # }
        #     attacher.add_derivatives(cropped: cropped)
        #     attacher.derivatives #=>
        #     # {
        #     #   thumb: #<Shrine::UploadedFile>,
        #     #   cropped: #<Shrine::UploadedFile>,
        #     # }
        def add_derivatives(files, **options)
          new_derivatives = upload_derivatives(files, **options)
          set_derivatives { derivatives.merge(new_derivatives) }
          new_derivatives
        end

        # Uploads a given file and adds it to the derivatives hash.
        #
        #     attacher.derivatives #=>
        #     # {
        #     #   thumb: #<Shrine::UploadedFile>,
        #     # }
        #     attacher.add_derivative(:cropped, cropped)
        #     attacher.derivatives #=>
        #     # {
        #     #   thumb: #<Shrine::UploadedFile>,
        #     #   cropped: #<Shrine::UploadedFile>,
        #     # }
        def add_derivative(name, file, **options)
          add_derivatives({ name => file }, **options)
          derivatives[name]
        end

        # Uploads given hash of files.
        #
        #     hash = attacher.upload_derivatives(thumb: thumb)
        #     hash[:thumb] #=> #<Shrine::UploadedFile>
        def upload_derivatives(files, **options)
          files = process_derivatives(files) if files.is_a?(Symbol)

          map_derivative(files) do |path, file|
            path = derivative_path(path)

            upload_derivative(path, file, **options)
          end
        end

        # Uploads the given file and deletes it afterwards.
        #
        #     hash = attacher.upload_derivative(:thumb, thumb)
        #     hash[:thumb] #=> #<Shrine::UploadedFile>
        def upload_derivative(path, file, storage: nil, delete: true, **options)
          storage  ||= derivatives_storage(path)
          derivative = upload(file, storage, derivative: path, **options)

          delete_file(file) if file.respond_to?(:path) && delete

          derivative
        end

        # Downloads the attached file and calls the specified processor.
        #
        #     Shrine::Attacher.derivatives_processor :thumbnails do |original|
        #       processor = ImageProcessing::MiniMagick.source(original)
        #
        #       {
        #         small:  processor.resize_to_limit!(300, 300),
        #         medium: processor.resize_to_limit!(500, 500),
        #         large:  processor.resize_to_limit!(800, 800),
        #       }
        #     end
        #
        #     attacher.process_derivatives(:thumbnails)
        #     #=> { small: #<File:...>, medium: #<File:...>, large: #<File:...> }
        def process_derivatives(processor_name, original = nil, **options)
          processor = derivatives_processor(processor_name)

          if original
            result = _process_derivatives(processor_name, original, **options)
          else
            result = file!.download do |original|
              _process_derivatives(processor_name, original, **options)
            end
          end

          unless result.is_a?(Hash)
            fail Error, "expected derivatives processor #{processor_name.inspect} to return a Hash, got #{result.inspect}"
          end

          result
        end

        # Removes derivatives with specified name from the derivatives hash.
        #
        #     attacher.derivatives #=> { one: #<Shrine::UploadedFile>, two: #<Shrine::UploadedFile> }
        #     attacher.remove_derivative(:one) #=> #<Shrine::UploadedFile> (removed derivative)
        #     attacher.derivatives #=> { two: #<Shrine::UploadedFile> }
        def remove_derivatives(*path)
          removed_derivatives = derivatives.dig(*path)
          set_derivatives do
            if path.one?
              derivatives.delete(*path)
            else
              derivatives.dig(*path[0..-2]).delete(path[-1])
            end
            derivatives
          end
          removed_derivatives
        end
        alias remove_derivative remove_derivatives

        # Sets the given hash of uploaded files as derivatives.
        #
        #     attacher.set_derivatives { { thumb: uploaded_file } }
        #     attacher.derivatives #=> { thumb: #<Shrine::UploadedFile> }
        def set_derivatives
          @derivatives_mutex.synchronize do
            self.derivatives = yield derivatives
            set file # trigger model writing
          end
          derivatives
        end

        # Adds derivative data into the hash.
        #
        #     attacher.attach(io)
        #     attacher.add_derivatives(thumb: thumb)
        #     attacher.data
        #     #=>
        #     # {
        #     #   "id" => "...",
        #     #   "storage" => "store",
        #     #   "metadata" => { ... },
        #     #   "derivatives" => {
        #     #     "thumb" => {
        #     #       "id" => "...",
        #     #       "storage" => "store",
        #     #       "metadata" => { ... },
        #     #     }
        #     #   }
        #     # }
        def data
          result = super

          if derivatives.any?
            result ||= {}
            result["derivatives"] = map_derivative(derivatives, transform_keys: :to_s) do |_, derivative|
              derivative.data
            end
          end

          result
        end

        # Loads derivatives from data generated by `Attacher#data`.
        #
        #     attacher.load_data({
        #       "id" => "...",
        #       "storage" => "store",
        #       "metadata" => { ... },
        #       "derivatives" => {
        #         "thumb" => {
        #           "id" => "...",
        #           "storage" => "store",
        #           "metadata" => { ... },
        #         }
        #       }
        #     })
        #     attacher.file        #=> #<Shrine::UploadedFile>
        #     attacher.derivatives #=> { thumb: #<Shrine::UploadedFile> }
        def load_data(data)
          data ||= {}
          data   = data.dup

          derivatives_data = data.delete("derivatives") || data.delete(:derivatives) || {}
          @derivatives     = shrine_class.derivatives(derivatives_data)

          data = nil if data.empty?

          super(data)
        end

        # Clears derivatives when attachment changes.
        #
        #     attacher.derivatives #=> { thumb: #<Shrine::UploadedFile> }
        #     attacher.change(file)
        #     attacher.derivatives #=> {}
        def change(*args)
          result = super
          set_derivatives { Hash.new }
          result
        end

        # Sets a hash of derivatives.
        #
        #     attacher.derivatives = { thumb: Shrine.uploaded_file(...) }
        #     attacher.derivatives #=> { thumb: #<Shrine::UploadedFile ...> }
        def derivatives=(derivatives)
          unless derivatives.is_a?(Hash)
            fail ArgumentError, "expected derivatives to be a Hash, got #{derivatives.inspect}"
          end

          @derivatives = derivatives
        end

        private

        # Calls the processor with the original file and options.
        def _process_derivatives(processor_name, original, **options)
          processor = derivatives_processor(processor_name)

          instrument_derivatives(processor_name, options) do
            instance_exec(original, **options, &processor)
          end
        end

        # Sends a `derivatives.shrine` event for instrumentation plugin.
        def instrument_derivatives(processor_name, processor_options, &block)
          return yield unless shrine_class.respond_to?(:instrument)

          shrine_class.instrument(
            :derivatives,
            processor:         processor_name,
            processor_options: processor_options,
            &block
          )
        end

        # Retrieves derivatives processor with specified name.
        def derivatives_processor(name)
          shrine_class.opts[:derivatives][:processors][name.to_sym] or
            fail Error, "derivatives processor #{name.inspect} not registered"
        end

        # Iterates through nested derivatives and maps results.
        #
        #     attacher.map_derivative { |name, file| ... }
        #     # or
        #     attacher.map_derivative(files) { |name, file| ... }
        def map_derivative(*args, &block)
          shrine_class.map_derivative(*args, &block)
        end

        # Returns symbolized array or single key.
        def derivative_path(path)
          path = path.map { |key| key.is_a?(String) ? key.to_sym : key }
          path = path.first if path.one?
          path
        end

        # Storage to which derivatives will be uploaded to by default.
        def derivatives_storage(path)
          storage = shrine_class.opts[:derivatives][:storage]
          storage = instance_exec(path, &storage) if storage.respond_to?(:call)
          storage
        end

        # Closes and deletes given file, ignoring if it's already deleted.
        def delete_file(file)
          file.close
          File.unlink(file.path)
        rescue Errno::ENOENT
        end
      end

      module ClassMethods
        # Converts data into a Hash of derivatives.
        #
        #     Shrine.derivatives('{"thumb":{"id":"foo","storage":"store","metadata":{}}}')
        #     #=> { thumb: #<Shrine::UploadedFile @id="foo" @storage="store" @metadata={}> }
        #
        #     Shrine.derivatives({ "thumb" => { "id" => "foo", "storage" => "store", "metadata" => {} } })
        #     #=> { thumb: #<Shrine::UploadedFile @id="foo" @storage="store" @metadata={}> }
        #
        #     Shrine.derivatives({ thumb: { id: "foo", storage: "store", metadata: {} } })
        #     #=> { thumb: #<Shrine::UploadedFile @id="foo" @storage="store" @metadata={}> }
        def derivatives(object)
          if object.is_a?(String)
            derivatives JSON.parse(object)
          elsif object.is_a?(Hash) || object.is_a?(Array)
            map_derivative(
              object,
              transform_keys: :to_sym,
              leaf: -> (value) { value.is_a?(Hash) && (value["id"] || value[:id]).is_a?(String) },
            ) { |_, value| uploaded_file(value) }
          else
            fail ArgumentError, "cannot convert #{object.inspect} to derivatives"
          end
        end

        # Iterates over a nested collection, yielding on each part of the path.
        # If the block returns a truthy value, that branch is terminated
        def map_derivative(object, path = [], transform_keys: :to_sym, leaf: nil, &block)
          return enum_for(__method__, object) unless block_given?

          if leaf && leaf.call(object)
            yield path, object
          elsif object.is_a?(Hash)
            object.inject({}) do |hash, (key, value)|
              key = key.send(transform_keys)

              hash.merge! key => map_derivative(
                value, [*path, key],
                transform_keys: transform_keys, leaf: leaf,
                &block
              )
            end
          elsif object.is_a?(Array)
            object.map.with_index do |value, idx|
              map_derivative(
                value, [*path, idx],
                transform_keys: transform_keys, leaf: leaf,
                &block
              )
            end
          else
            yield path, object
          end
        end
      end

      module FileMethods
        def [](*keys)
          if keys.any? { |key| key.is_a?(Symbol) }
            fail Error, "Shrine::UploadedFile#[] doesn't accept symbol metadata names. Did you happen to call `record.attachment[:derivative_name]` when you meant to call `record.attachment(:derivative_name)`?"
          else
            super
          end
        end
      end

      module VersionsCompatibility
        def load_data(data)
          return super if data.nil?
          return super if data["derivatives"] || data[:derivatives]
          return super if (data["id"] || data[:id]).is_a?(String)

          data     = data.dup
          original = data.delete("original") || data.delete(:original) || {}

          super original.merge("derivatives" => data)
        end
      end
    end

    register_plugin(:derivatives, Derivatives)
  end
end
