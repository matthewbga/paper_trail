module PaperTrail

  def self.included(base)
    base.send :extend, ClassMethods
  end


  module ClassMethods
    # Options:
    # :ignore    an array of attributes for which a new +Version+ will not be created if only they change.
    # :meta      a hash of extra data to store.  You must add a column to the versions table for each key.
    #            Values are objects or procs (which are called with +self+, i.e. the model with the paper
    #            trail).
    def has_paper_trail(options = {})
      send :include, InstanceMethods

      cattr_accessor :ignore
      self.ignore = (options[:ignore] || []).map &:to_s

      cattr_accessor :meta
      self.meta = options[:meta] || {}
      
      cattr_accessor :paper_trail_active
      self.paper_trail_active = true

      has_many :versions, :as => :item, :order => 'created_at ASC, id ASC'

      after_create  :record_create
      before_update :record_update
      after_destroy :record_destroy

      self.send(:define_method, "reified!") { @_reified = true }
      self.send(:define_method, "reified?") { !!@_reified }
    end

    def paper_trail_off
      self.paper_trail_active = false
    end

    def paper_trail_on
      self.paper_trail_active = true
    end
  end


  module InstanceMethods
    def record_create
      if self.class.paper_trail_active && PaperTrail.enabled?
        versions.create merge_metadata(:event => 'create', :whodunnit => PaperTrail.whodunnit)
      end
    end

    def record_update
      if changed_and_we_care? && self.class.paper_trail_active && PaperTrail.enabled?
        versions.build merge_metadata(:event     => 'update',
                                      :object    => object_to_string(previous_version),
                                      :whodunnit => PaperTrail.whodunnit)
      end
    end

    def record_destroy
      if self.class.paper_trail_active && PaperTrail.enabled?
        versions.create merge_metadata(:event     => 'destroy',
                                       :object    => object_to_string(previous_version),
                                       :whodunnit => PaperTrail.whodunnit)
      end
    end

    # Returns the object at the version that was valid at the given timestamp.
    def version_at(timestamp)
      # short-circuit if the current state is valid
      return self if self.updated_at <= timestamp

      version = versions.first(
        :conditions => ['created_at > ?', timestamp],
        :order => 'created_at ASC')
      version.reify if version
    end

    # Walk the versions to construct an audit trail of the edits made
    # over time, and by whom.
    def audit_trail(options={})
      # ignore updated_at by default because the version's created_at is good enough
      options[:attributes_to_ignore] = Array(options[:attributes_to_ignore] || %w(updated_at))
      audit_trail = []

      versions_desc = versions_including_current_in_descending_order

      versions_desc.each_with_index do |version, index|
        previous_version = versions_desc[index + 1]
        break if previous_version.nil?

        attributes_after = yaml_to_hash(version.object)
        attributes_before = yaml_to_hash(previous_version.object)

        # remove some attributes that we don't need to report
        [attributes_before, attributes_after].each do |hash|
          hash.reject! { |k,v| options[:attributes_to_ignore].include?(k) }
        end

        audit_trail << {
          :event => previous_version.event,
          :changed_by => transform_whodunnit(previous_version.whodunnit),
          :changed_at => previous_version.created_at,
          :changes => differences(attributes_before, attributes_after)
          }
      end

      audit_trail
    end

    protected

    # Override this method in your model to transform the whodunnit string
    # into something domain-specific. For example, to fetch a User instance by
    # its id.
    def transform_whodunnit(whodunnit)
      whodunnit
    end


    private

    def merge_metadata(data)
      meta.each do |k,v|
        data[k] = v.respond_to?(:call) ? v.call(self) : v
      end
      data
    end

    def previous_version
      previous = self.clone
      previous.id = id
      changes.each do |attr, ary|
        previous.send "#{attr}=", ary.first
      end
      previous
    end

    def object_to_string(object)
      object.attributes.to_yaml
    end

    def yaml_to_hash(yaml)
      return {} if yaml.nil?
      YAML::load(yaml).to_hash
    end

    # Returns an array of hashes, where each hash specifies the +:attribute+,
    # value +:before+ the change, and value +:after+ the change.
    def differences(before, after)
      before.diff(after).keys.sort.inject([]) do |diffs, k|
        diff = { :attribute => k, :before => before[k], :after => after[k] }
        diffs << diff; diffs
      end
    end

    # Returns all versions, newest first, including a pseudo-version that
    # represents the current version of the entity.
    def versions_including_current_in_descending_order
      v = self.versions.dup
      v << Version.new(:event => 'update',
        :object => object_to_string(self),
        :created_at => self.updated_at)
      v.reverse # newest first
    end
    
    def changed_and_we_care?
      changed? and !(changed - self.class.ignore).empty?
    end
  end

end

ActiveRecord::Base.send :include, PaperTrail
