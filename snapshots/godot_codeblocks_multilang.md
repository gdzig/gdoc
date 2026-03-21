Iterate through collisions:


```gdscript
for i in get_slide_collision_count():
    var collision = get_slide_collision(i)
    print(collision.get_collider().name)
```


```csharp
for (int i = 0; i < GetSlideCollisionCount(); i++)
{
    var collision = GetSlideCollision(i);
    GD.Print(collision.GetCollider().Name);
}
```


See `move_and_slide()`.