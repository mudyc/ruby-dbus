# dbus/introspection.rb - module containing a low-level D-Bus introspection implementation
#
# This file is part of the ruby-dbus project
# Copyright (C) 2007 Arnaud Cornet and Paul van Tilburg
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License, version 2.1 as published by the Free Software Foundation.
# See the file "COPYING" for the exact licensing terms.

require 'thread'

module DBus

  # DBus error which may be raised as an answer to a 
  # method call.
  #
  #    dbus_interface "com.example.ruby" do
  #      dbus_method :FireError do
  #        raise DBusError.new('epic fail')
  #      end
  #    end
  #
  class DBusError < StandardError
    @description = ''
    def initialize(error_name='org.freedesktop.DBus.Error.Fail', description=nil)
      @error_name = error_name
      @description = description if description != nil
    end
    def error_name
      @error_name
    end
    def description
      @description
    end
  end

  # Exception raised when an interface cannot be found in an object.
  class InterfaceNotInObject < Exception
  end

  # Exception raised when a method cannot be found in an inferface.
  class MethodNotInInterface < Exception
  end

  # Method raised when a method returns an invalid return type.
  class InvalidReturnType < Exception
  end

  # Exported object type
  # = Exportable D-Bus object class
  #
  # Objects that are going to be exported by a D-Bus service
  # should inherit from this class.
  class Object
    # The path of the object.
    attr_reader :path
    # The interfaces that the object supports.
    attr_reader :intfs
    # The service that the object is exported by.
    attr_writer :service

    @@intfs = Hash.new
    @@cur_intf = nil
    @@intfs_mutex = Mutex.new

    # Create a new object with a given _path_.
    def initialize(path)
      @path = path
      @intfs = @@intfs.dup
      @service = nil
    end

    # State that the object implements the given _intf_.
    def implements(intf)
      @intfs[intf.name] = intf
    end

    # Dispatch a message _msg_.
    def dispatch(msg)
      case msg.message_type
      when Message::METHOD_CALL
        reply = nil
        if not @intfs[msg.interface]
          puts "InterfaceNotInObject #{msg.interface}"
          reply = Message.error(msg, 'org.freedesktop.DBus.Error.UnknownInterface', msg.interface)
        else
          meth = @intfs[msg.interface].methods[msg.member.to_sym]
          if not meth
            puts "MethodNotInInterface #{msg.interface} #{msg.member.to_sym}"
            reply = Message.error(msg, 'org.freedesktop.DBus.Error.UnknownMethod', "#{msg.interface} #{msg.member.to_sym}")
          else
            methname = Object.make_method_name(msg.interface, msg.member)
            begin
              retdata = method(methname).call(*msg.params)
              retdata =  [*retdata]
              
              reply = Message.new.reply_to(msg)
              meth.rets.zip(retdata).each do |rsig, rdata|
                reply.add_param(rsig[1], rdata)
              end
            rescue => ex
              if ex.is_a? DBusError
                reply = Message.error(msg, ex.error_name, ex.description)
              else
                puts("DBus call Error: #{ex.to_s}")
                reply = Message.error(msg, "org.freedesktop.DBus.Error.Failed", "#{ex.class}: #{ex}\n==== Backtrace ====\n#{ex.backtrace.join("\n")}")
              end
            end
          end
        end
        @service.bus.send(reply.marshall)
      end
    end

    # Select (and create) the interface that the following defined methods
    # belong to.
    def self.dbus_interface(s)
      @@intfs_mutex.synchronize do
        @@cur_intf = @@intfs[s] = Interface.new(s)
        yield
        @@cur_intf = nil
      end
    end

    # Dummy undefined interface class.
    class UndefinedInterface
    end

    # Defines an exportable method on the object with the given name _sym_,
    # _prototype_ and the code in a block.
    def self.dbus_method(sym, protoype = "", &block)
      raise UndefinedInterface if @@cur_intf.nil?
      @@cur_intf.define(Method.new(sym.to_s).from_prototype(protoype))
      define_method(Object.make_method_name(@@cur_intf.name, sym.to_s), &block) 
    end

    # Emits a signal from the object with the given _interface_, signal
    # _sig_ and arguments _args_.
    def emit(intf, sig, *args)
      @service.bus.emit(@service, self, intf, sig, *args)
    end

    # Defines a signal for the object with a given name _sym_ and _prototype_.
    def self.dbus_signal(sym, protoype = "")
      raise UndefinedInterface if @@cur_intf.nil?
      cur_intf = @@cur_intf
      signal = Signal.new(sym.to_s).from_prototype(protoype)
      cur_intf.define(Signal.new(sym.to_s).from_prototype(protoype))
      define_method(sym.to_s) do |*args|
        emit(cur_intf, signal, *args)
      end
    end

    ####################################################################
    private

    # Helper method that returns a method name generated from the interface
    # name _intfname_ and method name _methname_.
    def self.make_method_name(intfname, methname)
      "#{intfname}%%#{methname}"
    end
  end # class Object
end # module DBus
