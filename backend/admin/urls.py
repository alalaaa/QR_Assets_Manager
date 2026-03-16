from django.contrib import admin
from django.urls import path
from django.http import HttpResponse

def hello_world(request):
    return HttpResponse("Hello World")


urlpatterns = [
    path('admin/', admin.site.urls),
    path('home/', hello_world)
]


