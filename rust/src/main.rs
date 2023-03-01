#[derive(serde::Serialize)]
enum TestUnion {
    X(i32),
    Y(u32),
}

#[derive(serde::Serialize)]
enum TestEnum {
    One,
    Two,
}

#[derive(serde::Serialize)]
struct TestType {
    u: TestUnion,
    e: TestEnum,
    s: &'static str,
    p: [f64; 2],
    o: Option<u8>,
    v: (),
}

fn dump(name: &str, result: &Vec<u8>) {
    print!("pub const {}: []const u8 = &.{{ ", name);
    for byte in result.iter() {
        print!("0x{:X}, ", byte);
    }
    println!(" }};");
}

fn example<T: serde::Serialize>(name: &str, value: &T) {
    let result = bincode::serialize(&value).unwrap();
    dump(name, &result);
}

fn main() {
    let test_type = TestType {
        u: TestUnion::Y(5),
        e: TestEnum::One,
        s: "abcdefgh",
        p: [1.1, 2.2],
        o: Some(255),
        v: (),
    };

    println!("// This file is generated using 'cargo run >examples.zig'");
    println!("");

    example::<TestType>("test_type", &test_type);
    example::<TestUnion>("test_union", &TestUnion::X(6));
    example::<TestEnum>("test_enum", &TestEnum::Two);
    example::<Option<u8>>("none", &None);
    example::<i8>("int_i8", &100);
    example::<u8>("int_u8", &101);
    example::<i16>("int_i16", &102);
    example::<u16>("int_u16", &103);
    example::<i32>("int_i32", &104);
    example::<u32>("int_u32", &105);
    example::<i64>("int_i64", &106);
    example::<u64>("int_u64", &107);
    example::<i128>("int_i128", &108);
    example::<u128>("int_u128", &109);
    example::<f32>("int_f32", &5.5);
    example::<f64>("int_f64", &6.6);
    example::<bool>("bool_false", &false);
    example::<bool>("bool_true", &true);
}
