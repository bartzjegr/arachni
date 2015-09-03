=begin
    Copyright 2010-2015 Tasos Laskos <tasos.laskos@arachni-scanner.com>

    This file is part of the Arachni Framework project and is subject to
    redistribution and commercial restrictions. Please see the Arachni Framework
    web site for more information on licensing and terms of use.
=end

require 'uri'
require 'ipaddr'
require 'addressable/uri'
require_relative 'uri/scope'

module Arachni

    # Helper method which parses a URL using {Arachni::URI.parse}.
    #
    # @see Arachni::URI.parse
    def self.URI( uri )
        Arachni::URI.parse( uri )
    end

# The URI class automatically normalizes the URLs it is passed to parse
# while maintaining compatibility with Ruby's URI core class.
#
# It also provides *cached* (to maintain a low latency) helper class methods to
# ease common operations such as:
#
# * {.normalize Normalization}.
# * Parsing to {.parse Arachni::URI} (see also {.URI}) or {.fast_parse Hash} objects.
# * Conversion to {.to_absolute absolute URLs}.
#
# @author Tasos "Zapotek" Laskos <tasos.laskos@arachni-scanner.com>
class URI
    include UI::Output
    extend  UI::Output

    include Utilities
    extend  Utilities

    # {URI} error namespace.
    #
    # All {URI} errors inherit from and live under it.
    #
    # @author Tasos "Zapotek" Laskos <tasos.laskos@arachni-scanner.com>
    class Error < Arachni::Error
    end

    CACHE_SIZES = {
        parse:       1000,
        fast_parse:  1000,
        encode:      1000,
        decode:      1000,
        normalize:   1000,
        to_absolute: 1000
    }

    CACHE = {
        parser: ::URI::Parser.new
    }
    CACHE_SIZES.each do |name, size|
        CACHE[name] = Support::Cache::LeastRecentlyPushed.new( size )
    end

    class <<self

        # @return [URI::Parser] cached URI parser
        def parser
            CACHE[__method__]
        end

        # URL encodes a string.
        #
        # @param [String] string
        # @param [String, Regexp] good_characters
        #   Class of characters to allow -- if {String} is passed, it should
        #   formatted as a regexp (for `Regexp.new`).
        #
        # @return   [String]
        #   Encoded string.
        def encode( string, good_characters = nil )
            CACHE[__method__][[string, good_characters]] ||=
                Addressable::URI.encode_component( *[string, good_characters].compact )
        end

        # URL decodes a string.
        #
        # @param [String] string
        #
        # @return   [String]
        def decode( string )
            CACHE[__method__][string] ||= Addressable::URI.unencode( string )
        end

        # @note This method's results are cached for performance reasons.
        #   If you plan on doing something destructive with its return value
        #   duplicate it first because there may be references to it elsewhere.
        #
        # Cached version of {URI#initialize}, if there's a chance that the same
        # URL will be needed to be parsed multiple times you should use this method.
        #
        # @see URI#initialize
        def parse( url )
            return url if !url || url.is_a?( Arachni::URI )
            CACHE[__method__][url] ||= begin
                new( url )
            rescue => e
                print_debug "Failed to parse '#{url}'."
                print_debug "Error: #{e}"
                print_debug_backtrace( e )
                nil
            end
        end

        # @note This method's results are cached for performance reasons.
        #   If you plan on doing something destructive with its return value
        #   duplicate it first because there may be references to it elsewhere.
        #
        # Performs a parse that is less resource intensive than Ruby's URI lib's
        # method while normalizing the URL (will also discard the fragment and
        # path parameters).
        #
        # @param    [String]  url
        #
        # @return   [Hash]
        #   URL components (frozen):
        #
        #     * `:scheme` -- HTTP or HTTPS
        #     * `:userinfo` -- `username:password`
        #     * `:host`
        #     * `:port`
        #     * `:path`
        #     * `:query`
        def fast_parse( url )
            return if !url || url.empty?
            return if url.downcase.start_with? 'javascript:'

            cache = CACHE[__method__]

            # One for reference.
            c_url = url
            # One to rip apart.
            url   = url.dup

            # Remove the fragment if there is one.
            url.sub!( /#.*/, '' )

            components = {
                scheme:   nil,
                userinfo: nil,
                host:     nil,
                port:     nil,
                path:     nil,
                query:    nil
            }

            valid_schemes = %w(http https)

            begin
                if (v = cache[url]) && v == :err
                    return
                elsif v
                    return v
                end

                # Parsing the URL in its schemeless form is trickier, so we
                # fake it, pass a valid scheme to get through the parsing and
                # then remove it at the other end.
                if (schemeless = url.start_with?( '//' ))
                    url = "http:#{url}"
                end

                url.recode!
                url = html_decode( url )

                dupped_url = url.dup
                has_path = true

                splits = url.split( ':' )
                if !splits.empty? && valid_schemes.include?( splits.first.downcase )

                    splits = url.split( '://', 2 )
                    components[:scheme] = splits.shift
                    components[:scheme].downcase! if components[:scheme]

                    if (url = splits.shift)
                        splits = url.to_s.split( '?' ).first.to_s.split( '@', 2 )

                        if splits.size > 1
                            components[:userinfo] = splits.first
                            url = splits.shift
                        end

                        if !splits.empty?
                            splits = splits.last.split( '/', 2 )
                            url = splits.last

                            splits = splits.first.split( ':', 2 )
                            if splits.size == 2
                                host = splits.first

                                if splits.last && !splits.last.empty?
                                    components[:port] = Integer( splits.last )
                                end

                                if components[:port] == 80
                                    components[:port] = nil
                                end

                                url.sub!( ":#{components[:port]}", '' )
                            else
                                host = splits.last
                            end

                            if (components[:host] = host)
                                url.sub!( host, '' )
                                components[:host].downcase!
                            end
                        else
                            has_path = false
                        end
                    else
                        has_path = false
                    end
                end

                if has_path
                    splits = url.split( '?', 2 )
                    if (components[:path] = splits.shift)
                        if components[:scheme]
                            components[:path] = "/#{components[:path]}"
                        end

                        components[:path].gsub!( /\/+/, '/' )

                        # Remove path params
                        components[:path].sub!( /\;.*/, '' )

                        if components[:path]
                            components[:path] =
                                encode( decode( components[:path] ),
                                        Addressable::URI::CharacterClasses::PATH ).dup

                            components[:path].gsub!( ';', '%3B' )
                        end
                    end

                    if c_url.include?( '?' ) &&
                        !(query = dupped_url.split( '?', 2 ).last).empty?

                        components[:query] = (query.split( '&', -1 ).map do |pair|
                            encode(
                                decode( pair ),
                                Addressable::URI::CharacterClasses::QUERY.sub( '\\&', '' )
                            )
                        end).join( '&' )
                    end
                end

                if schemeless
                    components.delete :scheme
                end

                components[:path] ||= components[:scheme] ? '/' : nil

                components.values.each(&:freeze)

                cache[c_url] = components.freeze
            rescue => ex
                ap ex
                ap ex.backtrace

                print_debug "Failed to parse '#{c_url}'."
                print_debug "Error: #{ex}"
                print_debug_backtrace( ex )

                cache[c_url] = :err
                nil
            end
        end

        # @note This method's results are cached for performance reasons.
        #   If you plan on doing something destructive with its return value
        #   duplicate it first because there may be references to it elsewhere.
        #
        # {.normalize Normalizes} and converts a `relative` URL to an absolute
        # one by merging in with a `reference` URL.
        #
        # Pretty much a cached version of {#to_absolute}.
        #
        # @param    [String]    relative
        # @param    [String]    reference
        #   Absolute url to use as a reference.
        #
        # @return   [String]
        #   Absolute URL (frozen).
        def to_absolute( relative, reference = Options.instance.url.to_s )
            return normalize( reference ) if !relative || relative.empty?
            key = [relative, reference].hash

            cache = CACHE[__method__]
            begin
                if (v = cache[key]) && v == :err
                    return
                elsif v
                    return v
                end

                parsed_ref = parse( reference )

                if relative.start_with?( '//' )
                    # Scheme-less URLs are expensive to parse so let's resolve
                    # the issue here.
                    relative = "#{parsed_ref.scheme}:#{relative}"
                end

                cache[key] = parse( relative ).to_absolute( parsed_ref ).to_s.freeze
            rescue
                cache[key] = :err
                nil
            end
        end

        # @note This method's results are cached for performance reasons.
        #   If you plan on doing something destructive with its return value
        #   duplicate it first because there may be references to it elsewhere.
        #
        # Uses {.fast_parse} to parse and normalize the URL and then converts
        # it to a common {String} format.
        #
        # @param    [String]    url
        #
        # @return   [String]
        #   Normalized URL (frozen).
        def normalize( url )
            return if !url || url.empty?

            cache = CACHE[__method__]

            url   = url.to_s.strip
            c_url = url.dup

            begin
                if (v = cache[url]) && v == :err
                    return
                elsif v
                    return v
                end

                cache[c_url] = parse( url ).to_s.freeze
            rescue => e
                print_debug "Failed to normalize '#{c_url}'."
                print_debug "Error: #{e}"
                print_debug_backtrace( e )

                cache[c_url] = :err
                nil
            end
        end

        # @param    [String]    url
        # @param    [Hash<Regexp => String>]    rules
        #   Regular expression and substitution pairs.
        #
        # @return  [String]
        #   Rewritten URL.
        def rewrite( url, rules = Arachni::Options.scope.url_rewrites )
            parse( url ).rewrite( rules ).to_s
        end

        # Extracts inputs from a URL query.
        #
        # @param    [String]    url
        #
        # @return   [Hash]
        def parse_query( url )
            parsed = parse( url )
            return {} if !parsed

            parse( url ).query_parameters
        end

        # @param    [String]    url
        #   URL to check.
        #
        # @return   [Bool]
        #   `true` is the URL is full and absolute, `false` otherwise.
        def full_and_absolute?( url )
            return false if url.to_s.empty?

            parsed = parse( url.to_s )
            return false if !parsed

            parsed.absolute?
        end
    end

    # @note Will discard the fragment component, if there is one.
    #
    # {.normalize Normalizes} and parses the provided URL.
    #
    # @param    [String]    url
    #   {String} URL to parse, `URI` to convert, or a `Hash` holding URL components
    #   (for `URI::Generic.build`). Also accepts {Arachni::URI} for convenience.
    def initialize( url )
        @data = self.class.fast_parse( url )

        fail Error, 'Failed to parse URL.' if !@data

        %w(scheme userinfo host port path query).each do |part|
            instance_variable_set( "@#{part}", @data[part.to_sym] )
        end

        reset_userpass
    end

    # @return   [Scope]
    def scope
        @scope ||= Scope.new( self )
    end

    def ==( other )
        to_s == other.to_s
    end

    def absolute?
        !!@scheme
    end

    def relative?
        !absolute?
    end

    # Converts self into an absolute URL using `reference` to fill in the
    # missing data.
    #
    # @param    [Arachni::URI, #to_s]    reference
    #   Full, absolute URL.
    #
    # @return   [Arachni::URI]
    #   Copy of self, as an absolute URL.
    def to_absolute!( reference )
        if !reference.is_a?( self.class )
            reference = self.class.new( reference.to_s )
        end

        %w(scheme userinfo host port).each do |part|
            next if send( part )

            ref_part = reference.send( "#{part}" )
            next if !ref_part

            send( "#{part}=", ref_part )
        end

        base_path = reference.path.split( %r{/+}, -1 )
        rel_path  = path.split( %r{/+}, -1 )

        # RFC2396, Section 5.2, 6), a)
        base_path << '' if base_path.last == '..'
        while (i = base_path.index( '..' ))
            base_path.slice!( i - 1, 2 )
        end

        if (first = rel_path.first) && first.empty?
            base_path.clear
            rel_path.shift
        end

        # RFC2396, Section 5.2, 6), c)
        # RFC2396, Section 5.2, 6), d)
        rel_path.push('') if rel_path.last == '.' || rel_path.last == '..'
        rel_path.delete('.')

        # RFC2396, Section 5.2, 6), e)
        tmp = []
        rel_path.each do |x|
            if x == '..' &&
                !(tmp.empty? || tmp.last == '..')
                tmp.pop
            else
                tmp << x
            end
        end

        add_trailer_slash = !tmp.empty?
        if base_path.empty?
            base_path = [''] # keep '/' for root directory
        elsif add_trailer_slash
            base_path.pop
        end

        while (x = tmp.shift)
            if x == '..'
                # RFC2396, Section 4
                # a .. or . in an absolute path has no special meaning
                base_path.pop if base_path.size > 1
            else
                # if x == '..'
                #   valid absolute (but abnormal) path "/../..."
                # else
                #   valid absolute path
                # end
                base_path << x
                tmp.each {|t| base_path << t}
                add_trailer_slash = false
                break
            end
        end

        base_path.push('') if add_trailer_slash
        @path = base_path.join('/')

        self
    end

    def to_absolute( reference )
        dup.to_absolute!( reference )
    end

    # @return   [String]
    #   The URL up to its resource component (query, fragment, etc).
    def without_query
        to_s.split( '?', 2 ).first.to_s
    end

    # @return   [String]
    #   Name of the resource.
    def resource_name
        path.split( '/' ).last
    end

    # @return   [String, nil]
    #   The extension of the URI {#file_name}, `nil` if there is none.
    def resource_extension
        name = resource_name.to_s
        return if !name.include?( '.' )

        name.split( '.' ).last
    end

    # @return   [String]
    #   The URL up to its path component (no resource name, query, fragment, etc).
    def up_to_path
        return if !path
        uri_path = path.dup

        uri_path = File.dirname( uri_path ) if !File.extname( path ).empty?

        uri_path << '/' if uri_path[-1] != '/'

        uri_str = "#{scheme}://#{host}"
        uri_str << ':' + port.to_s if port && port != 80
        uri_str << uri_path
    end

    # @return [String]
    #   `domain_name.tld`
    def domain
        return if !host
        return host if ip_address?

        s = host.split( '.' )
        return s.first if s.size == 1
        return host if s.size == 2

        s[1..-1].join( '.' )
    end

    # @param    [Hash<Regexp => String>]    rules
    #   Regular expression and substitution pairs.
    #
    # @return  [URI]
    #   Rewritten URL.
    def rewrite( rules = Arachni::Options.scope.url_rewrites )
        as_string = self.to_s

        rules.each do |args|
            if (rewritten = as_string.gsub( *args )) != as_string
                return Arachni::URI( rewritten )
            end
        end

        self.dup
    end

    # @return   [Boolean]
    #   `true` if the URI contains an IP address, `false` otherwise.
    def ip_address?
        !(IPAddr.new( host ) rescue nil).nil?
    end

    def query
        @query
    end

    def query=( q )
        q = q.to_s
        q = nil if q.empty?

        @query = q
    end

    # @return   [Hash]
    #   Extracted inputs from a URL query.
    def query_parameters
        q = self.query
        return {} if q.to_s.empty?

        q.split( '&' ).inject( {} ) do |h, pair|
            name, value = pair.split( '=', 2 )
            h[::URI.decode( name.to_s )] = ::URI.decode( value.to_s )
            h
        end
    end

    def userinfo=( ui )
        @userinfo = ui
    ensure
        reset_userpass
    end

    def userinfo
        @userinfo
    end

    def user
        @user
    end

    def password
        @password
    end

    def port
        @port
    end

    def port=( p )
        if p
            @port = p.to_i
        else
            @port = nil
        end
    end

    def host
        @host
    end

    def host=( h )
        @host = h
    end

    def path
        @path
    end

    def path=( p )
        @path = p
    end

    def scheme
        @scheme
    end

    def scheme=( s )
        @scheme = s
    end

    # @return   [String]
    def to_s
        s = ''

        if @scheme
            s << @scheme
            s << '://'
        end

        if @userinfo
            s << @userinfo
            s << '@'
        end

        if @host
            s << @host

            if @port
                if (@scheme == 'http' && @port != 80) ||
                    (@scheme == 'https' && @port != 443)

                    s << ':'
                    s << @port.to_s
                end
            end
        end

        s << @path

        if @query
            s << '?'
            s << @query
        end

        s
    end

    def dup
        self.class.new( to_s )
    end

    def _dump( _ )
        to_s
    end

    def self._load( url )
        new url
    end

    def hash
        to_s.hash
    end

    def persistent_hash
        to_s.persistent_hash
    end

    private

    def reset_userpass
        if @userinfo
            @user, @password = @userinfo.split( ':', -1 )
        else
            @user = @password = nil
        end
    end

    # Delegates unimplemented methods to Ruby's `URI::Generic` class for
    # compatibility.
    # def method_missing( sym, *args, &block )
    #     if @data.respond_to?( sym )
    #         @parsed_url.send( sym, *args, &block )
    #     else
    #         super
    #     end
    # end
    #
    # def respond_to?( *args )
    #     super || @parsed_url.respond_to?( *args )
    # end

end
end
