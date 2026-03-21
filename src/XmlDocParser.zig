const std = @import("std");
const Allocator = std.mem.Allocator;
const xml = @import("xml");

const docs_url = "https://docs.godotengine.org/en/stable";

pub const Tutorial = struct {
    title: []const u8,
    url: []const u8,
};

pub const ParamDoc = struct {
    name: []const u8,
    type: []const u8,
    default_value: ?[]const u8 = null,
};

pub const MemberDoc = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    qualifiers: ?[]const u8 = null,
    default_value: ?[]const u8 = null,
    return_type: ?[]const u8 = null,
    params: ?[]ParamDoc = null,
};

pub const ClassDoc = struct {
    name: []const u8,
    inherits: ?[]const u8 = null,
    brief_description: ?[]const u8 = null,
    description: ?[]const u8 = null,
    tutorials: ?[]Tutorial = null,
    methods: ?[]MemberDoc = null,
    properties: ?[]MemberDoc = null,
    signals: ?[]MemberDoc = null,
    constants: ?[]MemberDoc = null,
    constructors: ?[]MemberDoc = null,
    operators: ?[]MemberDoc = null,
};

pub const ParseError = error{
    MalformedXml,
    UnexpectedElement,
    MissingClassElement,
    MissingNameAttribute,
    OutOfMemory,
    ReadFailed,
};

pub fn parseClassDoc(allocator: Allocator, xml_content: []const u8) ParseError!ClassDoc {
    var static_reader: xml.Reader.Static = .init(allocator, xml_content, .{
        .namespace_aware = false,
    });
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    var doc: ClassDoc = .{ .name = "" };
    var tutorials: std.ArrayListUnmanaged(Tutorial) = .empty;
    defer tutorials.deinit(allocator);
    var methods: std.ArrayListUnmanaged(MemberDoc) = .empty;
    defer methods.deinit(allocator);
    var properties: std.ArrayListUnmanaged(MemberDoc) = .empty;
    defer properties.deinit(allocator);
    var signals: std.ArrayListUnmanaged(MemberDoc) = .empty;
    defer signals.deinit(allocator);
    var constants: std.ArrayListUnmanaged(MemberDoc) = .empty;
    defer constants.deinit(allocator);
    var constructors: std.ArrayListUnmanaged(MemberDoc) = .empty;
    defer constructors.deinit(allocator);
    var operators: std.ArrayListUnmanaged(MemberDoc) = .empty;
    defer operators.deinit(allocator);

    var found_class = false;

    while (true) {
        const node = reader.read() catch return ParseError.MalformedXml;
        switch (node) {
            .eof => break,
            .xml_declaration => continue,
            .element_start => {
                const name = reader.elementName();
                if (std.mem.eql(u8, name, "class")) {
                    found_class = true;
                    doc.name = try getAttributeAlloc(allocator, reader, "name") orelse return ParseError.MissingNameAttribute;
                    doc.inherits = try getAttributeAlloc(allocator, reader, "inherits");
                } else if (std.mem.eql(u8, name, "brief_description")) {
                    doc.brief_description = try readTextContent(allocator, reader);
                } else if (std.mem.eql(u8, name, "description") and found_class) {
                    doc.description = try readTextContent(allocator, reader);
                } else if (std.mem.eql(u8, name, "link")) {
                    const title = try getAttributeAlloc(allocator, reader, "title") orelse try allocator.dupe(u8, "");
                    const url_raw = try readTextContent(allocator, reader) orelse try allocator.dupe(u8, "");
                    const url = try expandDocsUrl(allocator, url_raw);
                    if (url.ptr != url_raw.ptr) {
                        allocator.free(url_raw);
                    }
                    try tutorials.append(allocator,.{ .title = title, .url = url });
                } else if (std.mem.eql(u8, name, "method")) {
                    const method_doc = try parseMethodElement(allocator, reader);
                    try methods.append(allocator, method_doc);
                } else if (std.mem.eql(u8, name, "member")) {
                    const member_name = try getAttributeAlloc(allocator, reader, "name") orelse continue;
                    const member_type = try getAttributeAlloc(allocator, reader, "type");
                    const member_default = try getAttributeAlloc(allocator, reader, "default");
                    const desc = try readTextContent(allocator, reader);
                    try properties.append(allocator, .{
                        .name = member_name,
                        .description = desc,
                        .return_type = member_type,
                        .default_value = member_default,
                    });
                } else if (std.mem.eql(u8, name, "signal")) {
                    const signal_doc = try parseMethodElement(allocator, reader);
                    try signals.append(allocator, signal_doc);
                } else if (std.mem.eql(u8, name, "constructor")) {
                    const ctor_doc = try parseMethodElement(allocator, reader);
                    try constructors.append(allocator, ctor_doc);
                } else if (std.mem.eql(u8, name, "operator")) {
                    const op_doc = try parseMethodElement(allocator, reader);
                    try operators.append(allocator, op_doc);
                } else if (std.mem.eql(u8, name, "constant")) {
                    const constant_name = try getAttributeAlloc(allocator, reader, "name") orelse continue;
                    const constant_value = try getAttributeAlloc(allocator, reader, "value");
                    const constant_enum = try getAttributeAlloc(allocator, reader, "enum");
                    const desc = try readTextContent(allocator, reader);
                    try constants.append(allocator, .{
                        .name = constant_name,
                        .description = desc,
                        .default_value = constant_value,
                        .qualifiers = constant_enum,
                    });
                }
            },
            else => continue,
        }
    }

    if (!found_class) return ParseError.MissingClassElement;

    doc.tutorials = if (tutorials.items.len > 0) try tutorials.toOwnedSlice(allocator) else null;
    doc.methods = if (methods.items.len > 0) try methods.toOwnedSlice(allocator) else null;
    doc.properties = if (properties.items.len > 0) try properties.toOwnedSlice(allocator) else null;
    doc.signals = if (signals.items.len > 0) try signals.toOwnedSlice(allocator) else null;
    doc.constants = if (constants.items.len > 0) try constants.toOwnedSlice(allocator) else null;
    doc.constructors = if (constructors.items.len > 0) try constructors.toOwnedSlice(allocator) else null;
    doc.operators = if (operators.items.len > 0) try operators.toOwnedSlice(allocator) else null;

    return doc;
}

pub fn freeClassDoc(allocator: Allocator, doc: ClassDoc) void {
    allocator.free(doc.name);
    if (doc.inherits) |s| allocator.free(s);
    if (doc.brief_description) |s| allocator.free(s);
    if (doc.description) |s| allocator.free(s);

    if (doc.tutorials) |tutorials| {
        for (tutorials) |t| {
            allocator.free(t.title);
            allocator.free(t.url);
        }
        allocator.free(tutorials);
    }

    inline for (.{ "methods", "properties", "signals", "constants", "constructors", "operators" }) |field| {
        if (@field(doc, field)) |members| {
            for (members) |m| {
                allocator.free(m.name);
                if (m.description) |d| allocator.free(d);
                if (m.qualifiers) |q| allocator.free(q);
                if (m.default_value) |dv| allocator.free(dv);
                if (m.return_type) |rt| allocator.free(rt);
                if (m.params) |params| {
                    for (params) |p| {
                        allocator.free(p.name);
                        allocator.free(p.type);
                        if (p.default_value) |pdv| allocator.free(pdv);
                    }
                    allocator.free(params);
                }
            }
            allocator.free(members);
        }
    }
}

fn getAttributeAlloc(allocator: Allocator, reader: *xml.Reader, name: []const u8) Allocator.Error!?[]const u8 {
    const idx = reader.attributeIndex(name) orelse return null;
    return try reader.attributeValueAlloc(allocator, idx);
}

fn readTextContent(allocator: Allocator, reader: *xml.Reader) ParseError!?[]const u8 {
    var text_buf: std.Io.Writer.Allocating = .init(allocator);
    defer text_buf.deinit();

    var depth: usize = 1;
    while (depth > 0) {
        const node = reader.read() catch return ParseError.MalformedXml;
        switch (node) {
            .eof => break,
            .element_start => depth += 1,
            .element_end => depth -= 1,
            .text => {
                text_buf.writer.writeAll(reader.textRaw()) catch return ParseError.OutOfMemory;
            },
            else => continue,
        }
    }

    const written = text_buf.written();
    if (written.len == 0) return null;

    const trimmed = std.mem.trim(u8, written, " \t\r\n");
    if (trimmed.len == 0) return null;

    return try allocator.dupe(u8, trimmed);
}

fn readNestedDescription(allocator: Allocator, reader: *xml.Reader, container_element: []const u8) ParseError!?[]const u8 {
    // Read through the container element looking for a nested <description> element.
    var depth: usize = 1;
    while (depth > 0) {
        const node = reader.read() catch return ParseError.MalformedXml;
        switch (node) {
            .eof => break,
            .element_start => {
                const name = reader.elementName();
                if (depth == 1 and std.mem.eql(u8, name, "description")) {
                    return try readTextContent(allocator, reader);
                }
                depth += 1;
            },
            .element_end => {
                const name = reader.elementName();
                if (depth == 1 and std.mem.eql(u8, name, container_element)) {
                    break;
                }
                depth -= 1;
            },
            else => continue,
        }
    }
    return null;
}

fn parseMethodElement(allocator: Allocator, reader: *xml.Reader) ParseError!MemberDoc {
    const method_name = try getAttributeAlloc(allocator, reader, "name") orelse return ParseError.MissingNameAttribute;
    const qualifiers = try getAttributeAlloc(allocator, reader, "qualifiers");

    var return_type: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var params: std.ArrayListUnmanaged(ParamDoc) = .empty;
    defer params.deinit(allocator);

    var depth: usize = 1;
    while (depth > 0) {
        const node = reader.read() catch return ParseError.MalformedXml;
        switch (node) {
            .eof => break,
            .element_start => {
                const name = reader.elementName();
                if (depth == 1 and std.mem.eql(u8, name, "return")) {
                    return_type = try getAttributeAlloc(allocator, reader, "type");
                    depth += 1;
                } else if (depth == 1 and std.mem.eql(u8, name, "param")) {
                    const param_name = try getAttributeAlloc(allocator, reader, "name") orelse try allocator.dupe(u8, "");
                    const param_type = try getAttributeAlloc(allocator, reader, "type") orelse try allocator.dupe(u8, "");
                    const param_default = try getAttributeAlloc(allocator, reader, "default");
                    try params.append(allocator, .{
                        .name = param_name,
                        .type = param_type,
                        .default_value = param_default,
                    });
                    depth += 1;
                } else if (depth == 1 and std.mem.eql(u8, name, "description")) {
                    description = try readTextContent(allocator, reader);
                } else {
                    depth += 1;
                }
            },
            .element_end => {
                depth -= 1;
            },
            else => continue,
        }
    }

    return .{
        .name = method_name,
        .description = description,
        .qualifiers = qualifiers,
        .return_type = return_type,
        .params = if (params.items.len > 0) try params.toOwnedSlice(allocator) else null,
    };
}

fn expandDocsUrl(allocator: Allocator, url: []const u8) Allocator.Error![]const u8 {
    const prefix = "$DOCS_URL";
    if (std.mem.startsWith(u8, url, prefix)) {
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ docs_url, url[prefix.len..] });
    }
    return url;
}

// Tests
const test_xml =
    \\<?xml version="1.0" encoding="UTF-8" ?>
    \\<class name="Node2D" inherits="CanvasItem" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    \\    <brief_description>A 2D game object.</brief_description>
    \\    <description>Node2D is the base class for 2D.</description>
    \\    <tutorials>
    \\        <link title="Custom drawing in 2D">$DOCS_URL/tutorials/2d/custom_drawing.html</link>
    \\        <link title="All 2D Demos">https://github.com/godotengine/godot-demo-projects/tree/master/2d</link>
    \\    </tutorials>
    \\    <methods>
    \\        <method name="apply_scale">
    \\            <return type="void" />
    \\            <param index="0" name="ratio" type="Vector2" />
    \\            <description>Multiplies the current scale by the ratio vector.</description>
    \\        </method>
    \\    </methods>
    \\    <members>
    \\        <member name="position" type="Vector2" setter="set_position" getter="get_position" default="Vector2(0, 0)">
    \\Position, relative to the node's parent.
    \\        </member>
    \\    </members>
    \\    <signals>
    \\        <signal name="some_signal">
    \\            <description>Emitted when something happens.</description>
    \\        </signal>
    \\    </signals>
    \\    <constants>
    \\        <constant name="MAX_VALUE" value="100">
    \\Maximum allowed value.
    \\        </constant>
    \\    </constants>
    \\</class>
;

test "parses class name and inherits" {
    const allocator = std.testing.allocator;
    const doc = try parseClassDoc(allocator, test_xml);
    defer freeClassDoc(allocator, doc);

    try std.testing.expectEqualStrings("Node2D", doc.name);
    try std.testing.expectEqualStrings("CanvasItem", doc.inherits.?);
}

test "parses brief_description and description" {
    const allocator = std.testing.allocator;
    const doc = try parseClassDoc(allocator, test_xml);
    defer freeClassDoc(allocator, doc);

    try std.testing.expectEqualStrings("A 2D game object.", doc.brief_description.?);
    try std.testing.expectEqualStrings("Node2D is the base class for 2D.", doc.description.?);
}

test "parses tutorials with $DOCS_URL expansion" {
    const allocator = std.testing.allocator;
    const doc = try parseClassDoc(allocator, test_xml);
    defer freeClassDoc(allocator, doc);

    const tutorials = doc.tutorials.?;
    try std.testing.expectEqual(2, tutorials.len);
    try std.testing.expectEqualStrings("Custom drawing in 2D", tutorials[0].title);
    try std.testing.expectEqualStrings(
        "https://docs.godotengine.org/en/stable/tutorials/2d/custom_drawing.html",
        tutorials[0].url,
    );
}

test "external tutorial URLs left unchanged" {
    const allocator = std.testing.allocator;
    const doc = try parseClassDoc(allocator, test_xml);
    defer freeClassDoc(allocator, doc);

    const tutorials = doc.tutorials.?;
    try std.testing.expectEqualStrings("All 2D Demos", tutorials[1].title);
    try std.testing.expectEqualStrings(
        "https://github.com/godotengine/godot-demo-projects/tree/master/2d",
        tutorials[1].url,
    );
}

test "parses methods with descriptions" {
    const allocator = std.testing.allocator;
    const doc = try parseClassDoc(allocator, test_xml);
    defer freeClassDoc(allocator, doc);

    const methods = doc.methods.?;
    try std.testing.expectEqual(1, methods.len);
    try std.testing.expectEqualStrings("apply_scale", methods[0].name);
    try std.testing.expectEqualStrings("Multiplies the current scale by the ratio vector.", methods[0].description.?);
}

test "parses properties from members element" {
    const allocator = std.testing.allocator;
    const doc = try parseClassDoc(allocator, test_xml);
    defer freeClassDoc(allocator, doc);

    const props = doc.properties.?;
    try std.testing.expectEqual(1, props.len);
    try std.testing.expectEqualStrings("position", props[0].name);
    try std.testing.expectEqualStrings("Position, relative to the node's parent.", props[0].description.?);
}

test "parses property default value" {
    const allocator = std.testing.allocator;
    const doc = try parseClassDoc(allocator, test_xml);
    defer freeClassDoc(allocator, doc);

    const props = doc.properties.?;
    try std.testing.expectEqual(1, props.len);
    try std.testing.expectEqualStrings("Vector2(0, 0)", props[0].default_value.?);
    try std.testing.expectEqualStrings("Vector2", props[0].return_type.?);
}

test "parses signals with descriptions" {
    const allocator = std.testing.allocator;
    const doc = try parseClassDoc(allocator, test_xml);
    defer freeClassDoc(allocator, doc);

    const sigs = doc.signals.?;
    try std.testing.expectEqual(1, sigs.len);
    try std.testing.expectEqualStrings("some_signal", sigs[0].name);
    try std.testing.expectEqualStrings("Emitted when something happens.", sigs[0].description.?);
}

test "parses constants with descriptions" {
    const allocator = std.testing.allocator;
    const doc = try parseClassDoc(allocator, test_xml);
    defer freeClassDoc(allocator, doc);

    const consts = doc.constants.?;
    try std.testing.expectEqual(1, consts.len);
    try std.testing.expectEqualStrings("MAX_VALUE", consts[0].name);
    try std.testing.expectEqualStrings("Maximum allowed value.", consts[0].description.?);
}

const test_xml_with_constructors_and_operators =
    \\<?xml version="1.0" encoding="UTF-8" ?>
    \\<class name="Vector2">
    \\    <brief_description>A 2D vector.</brief_description>
    \\    <description>2D vector type.</description>
    \\    <constructors>
    \\        <constructor name="Vector2">
    \\            <return type="Vector2" />
    \\            <description>Constructs a default Vector2.</description>
    \\        </constructor>
    \\        <constructor name="Vector2">
    \\            <return type="Vector2" />
    \\            <param index="0" name="x" type="float" />
    \\            <param index="1" name="y" type="float" />
    \\            <description>Constructs from x and y.</description>
    \\        </constructor>
    \\    </constructors>
    \\    <operators>
    \\        <operator name="operator +">
    \\            <return type="Vector2" />
    \\            <param index="0" name="right" type="Vector2" />
    \\            <description>Adds two vectors.</description>
    \\        </operator>
    \\    </operators>
    \\</class>
;

test "parses constructors" {
    const allocator = std.testing.allocator;
    const doc = try parseClassDoc(allocator, test_xml_with_constructors_and_operators);
    defer freeClassDoc(allocator, doc);

    const ctors = doc.constructors.?;
    try std.testing.expectEqual(2, ctors.len);
    try std.testing.expectEqualStrings("Vector2", ctors[0].name);
    try std.testing.expect(ctors[0].params == null);
    try std.testing.expectEqual(2, ctors[1].params.?.len);
}

test "parses operators" {
    const allocator = std.testing.allocator;
    const doc = try parseClassDoc(allocator, test_xml_with_constructors_and_operators);
    defer freeClassDoc(allocator, doc);

    const ops = doc.operators.?;
    try std.testing.expectEqual(1, ops.len);
    try std.testing.expectEqualStrings("operator +", ops[0].name);
    try std.testing.expectEqualStrings("Vector2", ops[0].return_type.?);
    try std.testing.expectEqual(1, ops[0].params.?.len);
}

const test_xml_with_enums =
    \\<?xml version="1.0" encoding="UTF-8" ?>
    \\<class name="Node">
    \\    <brief_description>Base class.</brief_description>
    \\    <description>Base node.</description>
    \\    <constants>
    \\        <constant name="NOTIFICATION_READY" value="13">Ready notification.</constant>
    \\        <constant name="PROCESS_MODE_INHERIT" value="0" enum="ProcessMode">Inherits process mode.</constant>
    \\        <constant name="PROCESS_MODE_ALWAYS" value="3" enum="ProcessMode">Always process.</constant>
    \\    </constants>
    \\</class>
;

test "parses constant value and enum attribute" {
    const allocator = std.testing.allocator;
    const doc = try parseClassDoc(allocator, test_xml_with_enums);
    defer freeClassDoc(allocator, doc);

    const consts = doc.constants.?;
    try std.testing.expectEqual(3, consts.len);

    // Regular constant — no enum
    try std.testing.expectEqualStrings("13", consts[0].default_value.?);
    try std.testing.expect(consts[0].qualifiers == null);

    // Enum constant — enum name stored in qualifiers field
    try std.testing.expectEqualStrings("0", consts[1].default_value.?);
    try std.testing.expectEqualStrings("ProcessMode", consts[1].qualifiers.?);
}

const test_xml_with_params =
    \\<?xml version="1.0" encoding="UTF-8" ?>
    \\<class name="Node2D" inherits="CanvasItem">
    \\    <brief_description>A 2D game object.</brief_description>
    \\    <description>Node2D is the base class for 2D.</description>
    \\    <methods>
    \\        <method name="get_angle_to" qualifiers="const">
    \\            <return type="float" />
    \\            <param index="0" name="point" type="Vector2" />
    \\            <description>Returns the angle between the node and the point.</description>
    \\        </method>
    \\        <method name="move_local_x">
    \\            <return type="void" />
    \\            <param index="0" name="delta" type="float" />
    \\            <param index="1" name="scaled" type="bool" default="false" />
    \\            <description>Applies a local translation on the X axis.</description>
    \\        </method>
    \\    </methods>
    \\</class>
;

test "parses method params and return type" {
    const allocator = std.testing.allocator;
    const doc = try parseClassDoc(allocator, test_xml_with_params);
    defer freeClassDoc(allocator, doc);

    const methods = doc.methods.?;
    try std.testing.expectEqual(2, methods.len);

    // First method: get_angle_to
    try std.testing.expectEqualStrings("const", methods[0].qualifiers.?);
    try std.testing.expectEqualStrings("float", methods[0].return_type.?);
    const params0 = methods[0].params.?;
    try std.testing.expectEqual(1, params0.len);
    try std.testing.expectEqualStrings("point", params0[0].name);
    try std.testing.expectEqualStrings("Vector2", params0[0].type);
    try std.testing.expect(params0[0].default_value == null);

    // Second method: move_local_x with default param
    const params1 = methods[1].params.?;
    try std.testing.expectEqual(2, params1.len);
    try std.testing.expectEqualStrings("false", params1[1].default_value.?);
}

test "freeClassDoc doesn't leak" {
    const allocator = std.testing.allocator;
    const doc = try parseClassDoc(allocator, test_xml);
    freeClassDoc(allocator, doc);
    // testing allocator will catch leaks
}
